import XCTest
@testable import TourMixCore

final class RotaryBallisticsTests: XCTestCase {
    func testThreeTierDynamicAcceleration() {
        var state = RotaryBallisticsState()
        let config = RotaryBallisticsConfig.standard

        // 1st step (no prior timestamp) -> slow tier (+0.5 dB)
        XCTAssertEqual(state.step(isClockwise: true, timestamp: 1.000, config: config), 0.5, accuracy: 1e-9)

        // Δt = 200 ms (> 110 ms) -> slow tier (+0.5 dB)
        XCTAssertEqual(state.step(isClockwise: true, timestamp: 1.200, config: config), 0.5, accuracy: 1e-9)

        // Exact upper boundary Δt = 110 ms (45..110 ms) -> medium tier (+1.0 dB)
        XCTAssertEqual(state.step(isClockwise: true, timestamp: 1.310, config: config), 1.0, accuracy: 1e-9)

        // Mid-range Δt = 70 ms (45..110 ms) -> medium tier (+1.0 dB)
        XCTAssertEqual(state.step(isClockwise: true, timestamp: 1.380, config: config), 1.0, accuracy: 1e-9)

        // Exact lower boundary Δt = 45 ms (45..110 ms) -> medium tier (+1.0 dB)
        XCTAssertEqual(state.step(isClockwise: true, timestamp: 1.425, config: config), 1.0, accuracy: 1e-9)

        // Fast spin Δt = 20 ms (< 45 ms) -> fast tier (+2.5 dB)
        XCTAssertEqual(state.step(isClockwise: true, timestamp: 1.445, config: config), 2.5, accuracy: 1e-9)
    }

    func testFineSlowStepAndFixedStepModes() {
        var fineState = RotaryBallisticsState()
        let fineConfig = RotaryBallisticsConfig(slowStepDb: 0.2)

        XCTAssertEqual(fineState.step(isClockwise: false, timestamp: 10.000, config: fineConfig), -0.2, accuracy: 1e-9)
        XCTAssertEqual(fineState.step(isClockwise: false, timestamp: 10.250, config: fineConfig), -0.2, accuracy: 1e-9)
        XCTAssertEqual(fineState.step(isClockwise: false, timestamp: 10.270, config: fineConfig), -2.5, accuracy: 1e-9)

        var fixedState = RotaryBallisticsState()
        let fixedConfig = RotaryBallisticsConfig.fixed(db: 1.5)
        XCTAssertEqual(fixedState.step(isClockwise: true, timestamp: 5.000, config: fixedConfig), 1.5, accuracy: 1e-9)
        // Even at Δt = 10 ms, fixed mode keeps constant 1.5 dB step
        XCTAssertEqual(fixedState.step(isClockwise: true, timestamp: 5.010, config: fixedConfig), 1.5, accuracy: 1e-9)
        XCTAssertEqual(fixedState.step(isClockwise: false, timestamp: 5.020, config: fixedConfig), -1.5, accuracy: 1e-9)
    }

    func testDirectionReversalImmediatelyResetsToSlowTier() {
        var state = RotaryBallisticsState()
        let config = RotaryBallisticsConfig.standard

        // Spin fast clockwise up to +2.5 dB tier
        XCTAssertEqual(state.step(isClockwise: true, timestamp: 2.000, config: config), 0.5, accuracy: 1e-9)
        XCTAssertEqual(state.step(isClockwise: true, timestamp: 2.020, config: config), 2.5, accuracy: 1e-9)
        XCTAssertEqual(state.step(isClockwise: true, timestamp: 2.040, config: config), 2.5, accuracy: 1e-9)

        // Reverse to counter-clockwise only 15 ms later (< 45 ms):
        // MUST reset lastStepTime and use slow fine step (-0.5 dB), NEVER -2.5 dB!
        let reverseFirstStep = state.step(isClockwise: false, timestamp: 2.055, config: config)
        XCTAssertEqual(reverseFirstStep, -0.5, accuracy: 1e-9)
        XCTAssertEqual(state.lastStepTime, 2.055)
        XCTAssertEqual(state.lastIsClockwise, false)

        // Continuing fast counter-clockwise (Δt = 20 ms from reversed step) accelerates normally in CCW
        XCTAssertEqual(state.step(isClockwise: false, timestamp: 2.075, config: config), -2.5, accuracy: 1e-9)

        // Reversing back to clockwise 10 ms later also resets to +0.5 dB
        XCTAssertEqual(state.step(isClockwise: true, timestamp: 2.085, config: config), 0.5, accuracy: 1e-9)
    }

    func testResetClearsVelocityHistory() {
        var state = RotaryBallisticsState()
        _ = state.step(isClockwise: true, timestamp: 3.000)
        XCTAssertEqual(state.step(isClockwise: true, timestamp: 3.020), 2.5, accuracy: 1e-9)

        state.reset()
        XCTAssertNil(state.lastStepTime)
        XCTAssertNil(state.lastIsClockwise)
        XCTAssertEqual(state.step(isClockwise: true, timestamp: 3.030), 0.5, accuracy: 1e-9)
    }

    func testZeroDbSafetyClampBoundaries() {
        // Crossing 0.0 dB from below -> clamps to 0.0 dB and sets hitZeroDbLock = true
        let clampedFromBelow = applyZeroDbSafetyClamp(currentDb: -1.0, deltaDb: 2.5, enabled: true)
        XCTAssertEqual(clampedFromBelow.targetDb, 0.0, accuracy: 1e-9)
        XCTAssertTrue(clampedFromBelow.hitZeroDbLock)

        // Already at 0.0 dB (or within 0.001 tolerance) turning CW -> stays locked at 0.0 dB with lock badge
        let lockedAtZero = applyZeroDbSafetyClamp(currentDb: 0.0, deltaDb: 0.5, enabled: true)
        XCTAssertEqual(lockedAtZero.targetDb, 0.0, accuracy: 1e-9)
        XCTAssertTrue(lockedAtZero.hitZeroDbLock)

        let lockedWithinEpsilon = applyZeroDbSafetyClamp(currentDb: 0.0008, deltaDb: 0.5, enabled: true)
        XCTAssertEqual(lockedWithinEpsilon.targetDb, 0.0, accuracy: 1e-9)
        XCTAssertTrue(lockedWithinEpsilon.hitZeroDbLock)

        // Landing exactly on 0.0 dB without overshoot -> targetDb = 0.0, hitZeroDbLock = false
        let exactLanding = applyZeroDbSafetyClamp(currentDb: -0.5, deltaDb: 0.5, enabled: true)
        XCTAssertEqual(exactLanding.targetDb, 0.0, accuracy: 1e-9)
        XCTAssertFalse(exactLanding.hitZeroDbLock)

        // Already at +2.0 dB (e.g. raised in TotalMix GUI) turning CCW -> decreases normally!
        let stepDownFromAboveZero = applyZeroDbSafetyClamp(currentDb: 2.0, deltaDb: -0.5, enabled: true)
        XCTAssertEqual(stepDownFromAboveZero.targetDb, 1.5, accuracy: 1e-9)
        XCTAssertFalse(stepDownFromAboveZero.hitZeroDbLock)

        // Already at +2.0 dB turning CW -> not <= 0.001, does not snap back to 0.0 dB
        let stepUpAboveZero = applyZeroDbSafetyClamp(currentDb: 2.0, deltaDb: 0.5, enabled: true)
        XCTAssertEqual(stepUpAboveZero.targetDb, 2.5, accuracy: 1e-9)
        XCTAssertFalse(stepUpAboveZero.hitZeroDbLock)

        // Safety clamp disabled -> passes through above 0.0 dB freely
        let disabledClamp = applyZeroDbSafetyClamp(currentDb: -1.0, deltaDb: 2.5, enabled: false)
        XCTAssertEqual(disabledClamp.targetDb, 1.5, accuracy: 1e-9)
        XCTAssertFalse(disabledClamp.hitZeroDbLock)
    }

    func testConfigCodableRoundTrip() throws {
        let configs: [RotaryBallisticsConfig] = [
            .standard,
            .fine,
            .fixed(db: 0.5)
        ]
        let data = try JSONEncoder().encode(configs)
        let decoded = try JSONDecoder().decode([RotaryBallisticsConfig].self, from: data)
        XCTAssertEqual(decoded, configs)
    }
}
