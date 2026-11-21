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

    func testConfigurableSafetyCeilingClampAndFormatting() {
        // Custom ceiling at -12.0 dB: upward crossing clamps to -12.0 dB with hitLimitLock = true
        let clampedNeg12 = applySafetyCeilingClamp(currentDb: -13.0, deltaDb: 2.5, enabled: true, maxDb: -12.0)
        XCTAssertEqual(clampedNeg12.targetDb, -12.0, accuracy: 1e-9)
        XCTAssertTrue(clampedNeg12.hitLimitLock)

        // Turning CW while already sitting at -12.0 dB stays locked
        let heldAtNeg12 = applySafetyCeilingClamp(currentDb: -12.0, deltaDb: 0.5, enabled: true, maxDb: -12.0)
        XCTAssertEqual(heldAtNeg12.targetDb, -12.0, accuracy: 1e-9)
        XCTAssertTrue(heldAtNeg12.hitLimitLock)

        // Exact landing on -6.0 dB without overshoot -> hitLimitLock = false
        let exactNeg6 = applySafetyCeilingClamp(currentDb: -7.0, deltaDb: 1.0, enabled: true, maxDb: -6.0)
        XCTAssertEqual(exactNeg6.targetDb, -6.0, accuracy: 1e-9)
        XCTAssertFalse(exactNeg6.hitLimitLock)

        // Turning CCW when currently above custom ceiling (-3.0 > -12.0) decreases normally
        let stepDownAboveCap = applySafetyCeilingClamp(currentDb: -3.0, deltaDb: -1.0, enabled: true, maxDb: -12.0)
        XCTAssertEqual(stepDownAboveCap.targetDb, -4.0, accuracy: 1e-9)
        XCTAssertFalse(stepDownAboveCap.hitLimitLock)

        // Custom ceiling above 0 dB (+3.0 dB) allows crossing 0 dB and clamps at +3.0 dB
        let clampedPos3 = applySafetyCeilingClamp(currentDb: 2.0, deltaDb: 2.5, enabled: true, maxDb: 3.0)
        XCTAssertEqual(clampedPos3.targetDb, 3.0, accuracy: 1e-9)
        XCTAssertTrue(clampedPos3.hitLimitLock)

        // Out-of-range ceiling inputs safely clamp into [-60.0, +6.0]
        XCTAssertEqual(VolumeSafetyLimit.clampCeilingDb(-999.0), -60.0, accuracy: 1e-9)
        XCTAssertEqual(VolumeSafetyLimit.clampCeilingDb(50.0), 6.0, accuracy: 1e-9)
        XCTAssertEqual(VolumeSafetyLimit.clampCeilingDb(-0.0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(VolumeSafetyLimit.clampCeilingDb(.nan), 0.0, accuracy: 1e-9)

        // Disabled custom ceiling ignores -18.5 dB limit
        let disabledCustom = applySafetyCeilingClamp(currentDb: -20.0, deltaDb: 5.0, enabled: false, maxDb: -18.5)
        XCTAssertEqual(disabledCustom.targetDb, -15.0, accuracy: 1e-9)
        XCTAssertFalse(disabledCustom.hitLimitLock)

        // Concise formatting & badge generation
        XCTAssertEqual(VolumeSafetyLimit.formatLimitDb(0.0), "0 dB")
        XCTAssertEqual(VolumeSafetyLimit.formatMaxBadge(0.0), "0 dB MAX")
        XCTAssertEqual(VolumeSafetyLimit.formatLimitDb(-12.0), "-12 dB")
        XCTAssertEqual(VolumeSafetyLimit.formatMaxBadge(-12.0), "-12 dB MAX")
        XCTAssertEqual(VolumeSafetyLimit.formatLimitDb(-12.5), "-12.5 dB")
        XCTAssertEqual(VolumeSafetyLimit.formatLimitDb(3.0), "+3 dB")
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
