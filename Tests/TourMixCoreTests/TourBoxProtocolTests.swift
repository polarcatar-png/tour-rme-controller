import XCTest
@testable import TourMixCore

final class TourBoxProtocolTests: XCTestCase {

    func testProtocolFrameConstantsAndExact94ByteConfig() {
        XCTAssertEqual(
            TourBoxProtocol.unlockCommand,
            [0x55, 0x00, 0x07, 0x88, 0x94, 0x00, 0x1A, 0xFE]
        )
        XCTAssertEqual(TourBoxProtocol.unlockCommand.count, 8)
        XCTAssertEqual(TourBoxProtocol.initConfigCommand.count, 94)

        let expectedHex = (
            "b5005d04" +
            "00050006000700080009000b000c000d" +
            "000e000f0026002700280029003b003c003d003e" +
            "003f004000410042004300440045004600470048" +
            "0049004a004b004c004d004e004f005000510052" +
            "0053005400a800a900aa00ab00fe"
        ).uppercased()

        let actualCompactHex = TourBoxProtocol.initConfigCommand
            .map { String(format: "%02X", $0) }
            .joined()
        XCTAssertEqual(actualCompactHex, expectedHex)

        XCTAssertTrue(TourBoxProtocol.isSupportedDevice(vendorID: 0xCAFE, productID: 0x4001))
        XCTAssertTrue(TourBoxProtocol.isSupportedDevice(vendorID: 0x2E3C, productID: 0x5740))
        XCTAssertTrue(TourBoxProtocol.isSupportedDevice(vendorID: 0xC251, productID: 0x2005))
        XCTAssertFalse(TourBoxProtocol.isSupportedDevice(vendorID: 0x05AC, productID: 0x1234))
    }

    func testWhitelistByteDecodingAndRotaryStopZeroSteps() {
        // 8 buttons * 2 (press + release) + 2 rotaries * 2 directions * 2 (step + stop) = 24 legal Lite bytes
        XCTAssertEqual(TourBoxDecodedByte.validSingleBytes.count, 24)
        XCTAssertEqual(TourBoxControlId.allCases.count, 8)

        for button in TourBoxButton.allCases {
            let pressDecoded = TourBoxProtocol.decode(button.pressByte)
            XCTAssertEqual(pressDecoded, .buttonPress(button))
            XCTAssertEqual(pressDecoded?.rawByte, button.pressByte)
            XCTAssertEqual(pressDecoded?.rotaryStepDelta, 0)

            let releaseDecoded = TourBoxProtocol.decode(button.releaseByte)
            XCTAssertEqual(releaseDecoded, .buttonRelease(button))
            XCTAssertEqual(releaseDecoded?.rawByte, button.releaseByte)
            XCTAssertEqual(releaseDecoded?.rotaryStepDelta, 0)
        }

        // Verify rotary trigger bytes -> .rotaryStep
        XCTAssertEqual(TourBoxProtocol.decode(0x44), .rotaryStep(.knob, .cw))
        XCTAssertEqual(TourBoxProtocol.decode(0x04), .rotaryStep(.knob, .ccw))
        XCTAssertEqual(TourBoxProtocol.decode(0x49), .rotaryStep(.scroll, .cw))
        XCTAssertEqual(TourBoxProtocol.decode(0x09), .rotaryStep(.scroll, .ccw))

        XCTAssertEqual(TourBoxProtocol.decode(0x44)?.rotaryStepDelta, 1)
        XCTAssertEqual(TourBoxProtocol.decode(0x04)?.rotaryStepDelta, -1)

        // Verify 0xC4 / 0x84 / 0xC9 / 0x89 MUST decode as .rotaryStop and count 0 steps
        let stopExpectations: [(UInt8, TourBoxRotary, RotaryDirection)] = [
            (0xC4, .knob, .cw),
            (0x84, .knob, .ccw),
            (0xC9, .scroll, .cw),
            (0x89, .scroll, .ccw)
        ]
        for (byte, rotary, direction) in stopExpectations {
            let decoded = TourBoxProtocol.decode(byte)
            XCTAssertEqual(decoded, .rotaryStop(rotary, direction))
            XCTAssertEqual(decoded?.isRotaryStop, true)
            XCTAssertEqual(decoded?.isRotaryStep, false)
            XCTAssertEqual(decoded?.rotaryStepDelta, 0)
        }

        // Verify Scroll UI direction copy maps cw->Up, ccw->Down
        XCTAssertTrue(RotaryDirection.cw.displayName(for: .scroll).contains("Up"))
        XCTAssertTrue(RotaryDirection.ccw.displayName(for: .scroll).contains("Down"))

        // Verify all non-whitelist bytes return nil (including firmware header 0x07, '<' 0x3C, Elite-only 0x01)
        for value in UInt8.min...UInt8.max where !TourBoxDecodedByte.validSingleBytes.contains(value) {
            XCTAssertNil(TourBoxProtocol.decode(value), "Byte 0x\(String(format: "%02X", value)) must not be whitelisted")
        }
    }

    func testFragmented26ByteHandshake20Plus6NeverLeaksZeroBytes() {
        var filter = TourBoxStreamFilter()
        XCTAssertEqual(filter.phase, .disconnected)

        // 1. Start handshake at t = 10.000
        let startOut = filter.beginHandshake(now: 10.000)
        XCTAssertEqual(filter.phase, .handshakingUnlock)
        XCTAssertEqual(startOut.commandsToWrite, [TourBoxProtocol.unlockCommand])
        XCTAssertTrue(startOut.inputs.isEmpty)

        // Real 26-byte firmware unlock response ending in 00 03 02 02 00 00
        let fullUnlockReply: [UInt8] = [
            0x07, 0xCA, 0x31, 0x78, 0x1B, 0xB2, 0xB5, 0xDB, 0x1D, 0xD5,
            0x6C, 0x07, 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
            0x00, 0x03, 0x02, 0x02, 0x00, 0x00
        ]
        XCTAssertEqual(fullUnlockReply.count, 26)

        let firstFragment20B = Array(fullUnlockReply.prefix(20))
        let secondFragment6B = Array(fullUnlockReply.suffix(6)) // [0x00, 0x03, 0x02, 0x02, 0x00, 0x00]

        // 2. Fragment 1 (20B) arrives at t = 10.004, Fragment 2 (6B) arrives 1ms later at t = 10.005
        let frag1Out = filter.ingest(firstFragment20B, now: 10.004)
        XCTAssertTrue(frag1Out.inputs.isEmpty)
        XCTAssertEqual(filter.phase, .handshakingUnlock)

        let frag2Out = filter.ingest(secondFragment6B, now: 10.005)
        XCTAssertTrue(frag2Out.inputs.isEmpty, "Trailing 6B fragment with 0x00 MUST NOT leak as Tall presses")
        XCTAssertEqual(filter.handshakeBuffer.count, 26)
        XCTAssertEqual(filter.phase, .handshakingUnlock)

        // 3. Before 15ms quiescence (at +10ms = 10.015), still waiting in .handshakingUnlock
        let earlyTick = filter.advanceTime(now: 10.015)
        XCTAssertEqual(filter.phase, .handshakingUnlock)
        XCTAssertTrue(earlyTick.commandsToWrite.isEmpty)

        // 4. At +15ms quiescence (t = 10.020), unlock completes and 94B initConfigCommand is emitted
        let quiescenceOut = filter.advanceTime(now: 10.020)
        XCTAssertEqual(filter.phase, .handshakingConfig)
        XCTAssertEqual(quiescenceOut.commandsToWrite, [TourBoxProtocol.initConfigCommand])
        XCTAssertTrue(quiescenceOut.inputs.isEmpty)

        // 5. Residual echo during 50ms config drain window (t = 10.045) is swallowed
        let drainEcho = filter.ingest([0x00, 0x02, 0x00], now: 10.045)
        XCTAssertTrue(drainEcho.inputs.isEmpty)
        XCTAssertEqual(filter.phase, .handshakingConfig)

        // 6. After 50ms config drain window (t = 10.070), enters .streaming and resets state machine
        let readyOut = filter.advanceTime(now: 10.070)
        XCTAssertEqual(filter.phase, .streaming)
        XCTAssertTrue(readyOut.didEnterStreaming)
        XCTAssertTrue(readyOut.resetStateMachine)

        // 7. Real 1-detent Knob CW rotation (0x44 + 0xC4) yields 1 step + 1 stop (only 1 actionable step)
        let knobTurn = filter.ingest([0x44, 0xC4], now: 10.100)
        XCTAssertEqual(knobTurn.inputs.map(\.decoded), [
            .rotaryStep(.knob, .cw),
            .rotaryStop(.knob, .cw)
        ])
        XCTAssertEqual(knobTurn.actionableInputs.map(\.decoded), [
            .rotaryStep(.knob, .cw)
        ])
    }

    func testNotAllowConfigBannerRetriesUnlockAndSupports300msWarmTimeoutFallback() {
        var filter = TourBoxStreamFilter()
        _ = filter.beginHandshake(now: 0.000)

        let banner = TourBoxProtocol.notAllowConfigBanner
        let partA = Array(banner.prefix(11))
        let partB = Array(banner.suffix(9))

        _ = filter.ingest(partA, now: 0.010)
        let retryOut = filter.ingest(partB, now: 0.012)
        XCTAssertEqual(filter.phase, .handshakingUnlock)
        XCTAssertEqual(filter.unlockAttempts, 2)
        XCTAssertEqual(retryOut.commandsToWrite, [TourBoxProtocol.unlockCommand])

        // Simulate warm device remaining silent for 300ms -> fallback transitions to .handshakingConfig
        let fallbackOut = filter.advanceTime(now: 0.312)
        XCTAssertEqual(filter.phase, .handshakingConfig)
        XCTAssertEqual(fallbackOut.commandsToWrite, [TourBoxProtocol.initConfigCommand])

        let streamOut = filter.advanceTime(now: 0.362)
        XCTAssertEqual(filter.phase, .streaming)
        XCTAssertTrue(streamOut.didEnterStreaming)
    }

    func testStreamingIllegalByteAndBurstTrigger40msQuarantineAndReset() {
        var filter = TourBoxStreamFilter()
        _ = filter.beginHandshake(now: 0.000)
        _ = filter.advanceTime(now: 0.300) // -> .handshakingConfig
        _ = filter.advanceTime(now: 0.350) // -> .streaming
        XCTAssertEqual(filter.phase, .streaming)

        // Valid single press works normally
        let normalPress = filter.ingest([0x22, 0xA2], now: 1.000)
        XCTAssertEqual(normalPress.inputs.count, 2)
        XCTAssertFalse(filter.isQuarantined)

        // Inject rogue response fragment starting with 0x07 alongside valid-looking byte 0x00 at t = 2.000
        let pollutedChunk1: [UInt8] = [0x07, 0xCA, 0x31, 0x00]
        let qStart = filter.ingest(pollutedChunk1, now: 2.000)
        XCTAssertTrue(qStart.enteredQuarantine)
        XCTAssertTrue(qStart.inputs.isEmpty, "Entire polluted batch must be discarded immediately")
        XCTAssertTrue(filter.isQuarantined)

        // Trailing 6-byte fragment of valid-looking codes [0x00, 0x03, 0x02, 0x02, 0x00, 0x00] arrives 5ms later
        let trailingValidLookingTail: [UInt8] = [0x00, 0x03, 0x02, 0x02, 0x00, 0x00]
        let qMid = filter.ingest(trailingValidLookingTail, now: 2.005)
        XCTAssertTrue(qMid.inputs.isEmpty, "Trailing 0x00 fragment inside 40ms quarantine MUST be dropped")
        XCTAssertFalse(qMid.resetStateMachine)
        XCTAssertTrue(filter.isQuarantined)

        // Still quarantined at +39ms (t = 2.039)
        let qBeforeEnd = filter.advanceTime(now: 2.039)
        XCTAssertTrue(filter.isQuarantined)
        XCTAssertFalse(qBeforeEnd.resetStateMachine)

        // Quarantine expires at +40ms (t = 2.040) and triggers resetStateMachine
        let qEnd = filter.advanceTime(now: 2.040)
        XCTAssertFalse(filter.isQuarantined)
        XCTAssertTrue(qEnd.resetStateMachine)

        // Burst >= 8 bytes of valid-looking 0x00 also triggers 40ms quarantine
        let burstZeros = [UInt8](repeating: 0x00, count: 8)
        let burstOut = filter.ingest(burstZeros, now: 3.000)
        XCTAssertTrue(burstOut.enteredQuarantine)
        XCTAssertTrue(burstOut.inputs.isEmpty)
        XCTAssertTrue(filter.isQuarantined)

        // Next valid input after 40ms (at t = 3.045) automatically settles quarantine reset and decodes cleanly
        let recovered = filter.ingest([0x02], now: 3.045)
        XCTAssertFalse(filter.isQuarantined)
        XCTAssertTrue(recovered.resetStateMachine)
        XCTAssertEqual(recovered.inputs.map(\.decoded), [.buttonPress(.top)])
    }
}
