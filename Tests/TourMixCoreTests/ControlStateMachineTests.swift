import XCTest
@testable import TourMixCore

final class ControlStateMachineTests: XCTestCase {

    func testPlainButtonZeroLatencyPressAndRelease() {
        var sm = ControlStateMachine()

        let down = sm.process(.buttonPress(.c1), timestamp: 1.000)
        XCTAssertEqual(down, [.buttonDown(button: .c1, modifier: nil)])

        // Duplicate press bounce is ignored while held
        let bounce = sm.process(.buttonPress(.c1), timestamp: 1.010)
        XCTAssertTrue(bounce.isEmpty)

        let up = sm.process(.buttonRelease(.c1), timestamp: 1.080)
        XCTAssertEqual(up, [.buttonUp(button: .c1, modifier: nil)])
    }

    func testRotaryStopIsStrictlyIgnoredAndDoesNotPolluteModifierTap() {
        var sm = ControlStateMachine(
            modifierButtons: [.tall],
            rotaryCombos: [.init(modifier: .tall, rotary: .knob)]
        )

        // Standalone rotary step + stop -> only 1 rotaryTurn
        XCTAssertEqual(
            sm.process(.rotaryStep(.knob, .cw), timestamp: 1.000),
            [.rotaryTurn(rotary: .knob, direction: .cw, modifier: nil, timestamp: 1.000)]
        )
        XCTAssertTrue(sm.process(.rotaryStop(.knob, .cw), timestamp: 1.003).isEmpty)

        // Hold Tall, receive a trailing .rotaryStop from a prior turn -> must NOT mark Tall as comboUsed!
        XCTAssertTrue(sm.process(.buttonPress(.tall), timestamp: 2.000).isEmpty)
        XCTAssertTrue(sm.process(.rotaryStop(.knob, .cw), timestamp: 2.002).isEmpty)

        // Releasing Tall still fires .buttonTapOnRelease(.tall)
        XCTAssertEqual(
            sm.process(.buttonRelease(.tall), timestamp: 2.090),
            [.buttonTapOnRelease(button: .tall)]
        )
    }

    func testModifierWithRotaryComboSuppressesModifierTapOnRelease() {
        var sm = ControlStateMachine(
            modifierButtons: [.tall],
            rotaryCombos: [.init(modifier: .tall, rotary: .knob)]
        )

        // Pressing modifier alone does NOT fire immediately
        XCTAssertTrue(sm.process(.buttonPress(.tall), timestamp: 5.000).isEmpty)

        // Turning Knob while Tall held fires modified rotaryTurn
        let turn = sm.process(.rotaryStep(.knob, .ccw), timestamp: 5.050)
        XCTAssertEqual(
            turn,
            [.rotaryTurn(rotary: .knob, direction: .ccw, modifier: .tall, timestamp: 5.050)]
        )
        XCTAssertTrue(sm.process(.rotaryStop(.knob, .ccw), timestamp: 5.053).isEmpty)

        // Releasing Tall after combo use MUST NOT fire .buttonTapOnRelease
        let releaseTall = sm.process(.buttonRelease(.tall), timestamp: 5.200)
        XCTAssertTrue(releaseTall.isEmpty)
    }

    func testModifierTapOnReleaseWhenNoComboUsed() {
        var sm = ControlStateMachine(
            modifierButtons: [.tall],
            buttonCombos: [.init(modifier: .tall, targetButton: .c1)]
        )

        XCTAssertTrue(sm.process(.buttonPress(.tall), timestamp: 3.000).isEmpty)
        let release = sm.process(.buttonRelease(.tall), timestamp: 3.120)
        XCTAssertEqual(release, [.buttonTapOnRelease(button: .tall)])
    }

    func testOutOfOrderComboReleaseModifierReleasedBeforeTarget() {
        var sm = ControlStateMachine(
            modifierButtons: [.tall],
            buttonCombos: [.init(modifier: .tall, targetButton: .c1)]
        )

        // 1. Hold Tall
        XCTAssertTrue(sm.process(.buttonPress(.tall), timestamp: 10.000).isEmpty)

        // 2. Press C1 -> emits combo buttonDown(button: .c1, modifier: .tall)
        let comboDown = sm.process(.buttonPress(.c1), timestamp: 10.040)
        XCTAssertEqual(comboDown, [.buttonDown(button: .c1, modifier: .tall)])

        // 3. Release Tall FIRST (out-of-order!) -> no tap on Tall, C1 combo stays tracked
        let releaseTallFirst = sm.process(.buttonRelease(.tall), timestamp: 10.100)
        XCTAssertTrue(releaseTallFirst.isEmpty)
        XCTAssertEqual(sm.activeCombos[.c1], .tall)

        // 4. Release C1 SECOND -> MUST emit buttonUp with originalModifier == .tall!
        let releaseC1Second = sm.process(.buttonRelease(.c1), timestamp: 10.160)
        XCTAssertEqual(releaseC1Second, [.buttonUp(button: .c1, modifier: .tall)])
        XCTAssertTrue(sm.activeCombos.isEmpty)
    }

    func testDoublePressDetectionAndSingleTapTimeoutFallback() {
        var sm = ControlStateMachine(
            doublePressButtons: [.tour],
            doubleClickWindowSec: 0.26
        )

        // Double press within 0.26s
        XCTAssertTrue(sm.process(.buttonPress(.tour), timestamp: 1.000).isEmpty)
        XCTAssertTrue(sm.process(.buttonRelease(.tour), timestamp: 1.060).isEmpty)
        let secondPress = sm.process(.buttonPress(.tour), timestamp: 1.180)
        XCTAssertEqual(secondPress, [.buttonDoublePress(button: .tour)])
        // Release of second tap is swallowed cleanly
        XCTAssertTrue(sm.process(.buttonRelease(.tour), timestamp: 1.240).isEmpty)

        // Single press exceeding 0.26s falls back to normal down+up on advanceTime
        XCTAssertTrue(sm.process(.buttonPress(.tour), timestamp: 2.000).isEmpty)
        XCTAssertTrue(sm.process(.buttonRelease(.tour), timestamp: 2.050).isEmpty)
        let timeoutFallback = sm.advanceTime(now: 2.260)
        XCTAssertEqual(timeoutFallback, [
            .buttonDown(button: .tour, modifier: nil),
            .buttonUp(button: .tour, modifier: nil)
        ])
    }

    func testResetReleasesAllActiveCombosAndPlainButtonsWithoutTapSideEffects() {
        var sm = ControlStateMachine(
            modifierButtons: [.tall, .short],
            buttonCombos: [.init(modifier: .tall, targetButton: .c1)]
        )

        // Hold Tall + C1 combo, hold Short unused modifier, hold Top plain button
        _ = sm.process(.buttonPress(.tall), timestamp: 1.000)
        _ = sm.process(.buttonPress(.c1), timestamp: 1.020)
        _ = sm.process(.buttonPress(.short), timestamp: 1.030)
        _ = sm.process(.buttonPress(.top), timestamp: 1.040)

        let cleanup = sm.reset()
        XCTAssertEqual(cleanup, [
            .buttonUp(button: .c1, modifier: .tall),
            .buttonUp(button: .top, modifier: nil)
        ])
        XCTAssertTrue(sm.activeCombos.isEmpty)
        XCTAssertTrue(sm.activePlainButtons.isEmpty)
        XCTAssertTrue(sm.activeModifiers.isEmpty)
    }

    func testKeyComboFormattingAndMediaKeys() {
        let cmdShiftZ = KeyCombo(keyCode: 0x06, shift: true, command: true)
        XCTAssertEqual(cmdShiftZ.displayLabel, "⇧⌘Z")
        XCTAssertTrue(cmdShiftZ.cgEventFlags.contains(.maskShift))
        XCTAssertTrue(cmdShiftZ.cgEventFlags.contains(.maskCommand))

        XCTAssertEqual(MediaKeyAction.playPause.nxKeyType, 16)
        XCTAssertEqual(MediaKeyAction.nextTrack.nxKeyType, 17)
        XCTAssertEqual(MediaKeyAction.previousTrack.nxKeyType, 18)
    }
}
