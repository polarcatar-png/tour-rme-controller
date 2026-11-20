import Foundation
import Testing
@testable import TourMixCore

@Suite("ProfileConfig 出厂极简配置与 CoordinatorEngine 端到端联动测试")
struct ProfileAndCoordinatorTests {
    @Test("ProfileConfig.factoryDefault 严格只含 Knob -> AN 1/2 (output 0) 唯一绑定，其余全空")
    func factoryDefaultIsStrictlyMinimal() {
        let profile = ProfileConfig.factoryDefault

        #expect(profile.rotaryBindings.count == 1)
        #expect(
            profile.rotaryBindings[.knob] == .rmeOutputFader(
                channelIndex: 0,
                ballistics: .standard,
                safetyClamp0dB: true
            )
        )
        #expect(profile.rotaryBindings[.scroll] == nil)
        #expect(profile.buttonBindings.isEmpty)
        #expect(profile.doublePressBindings.isEmpty)
        #expect(profile.modifierButtons.isEmpty)
        #expect(profile.rotaryComboBindings.isEmpty)
        #expect(profile.buttonComboBindings.isEmpty)
        #expect(profile.containsKeyboardShortcutBindings == false)

        let bound = profile.boundOutputChannels
        #expect(bound.count == 1)
        #expect(bound[0].channelIndex == 0)
        #expect(bound[0].safetyClamp0dB == true)

        // 验证 8 个机身控件摘要：仅 knob.primary 非空，其余全部为 (nil, nil)
        let summaries = profile.allBindingSummaries { bus, idx in
            FirefaceUCXProfile.stereoDefaultLabel(bus: bus, evenIndex: idx)
        }
        #expect(summaries[.knob]?.primary == "AN 1/2 音量")
        #expect(summaries[.knob]?.secondary == nil)
        for other in TourBoxControlId.allCases where other != .knob {
            #expect(summaries[other]?.primary == nil)
            #expect(summaries[other]?.secondary == nil)
        }
    }

    @Test("AppConfiguration 与复杂组合键预设 JSON 序列化/反序列化无损往返")
    func jsonCodableRoundTrip() throws {
        var customProfile = ProfileConfig.factoryDefault
        customProfile.name = "混音台工作流"
        customProfile.associatedBundleIdentifier = "com.apple.logic10"
        customProfile.modifierButtons = [.tour]
        customProfile.buttonBindings[.c1] = .rmeOutputMute(channelIndex: 0)
        customProfile.doublePressBindings[.top] = .rmeControlRoom(.dim)
        customProfile.rotaryComboBindings[.init(modifier: .tour, rotary: .knob)] = .rmeOutputFader(
            channelIndex: 6,
            ballistics: .fine,
            safetyClamp0dB: false
        )
        customProfile.buttonComboBindings[.init(modifier: .tour, targetButton: .short)] = .keyShortcut(
            KeyCombo(keyCode: 0x06, command: true) // Cmd+Z
        )

        let config = AppConfiguration(
            profiles: [.factoryDefault, customProfile],
            activeProfileId: customProfile.id,
            autoSwitchByFrontmostApp: true,
            showHUD: true,
            showDbInMenuBar: true,
            oscHost: "127.0.0.1",
            oscOutgoingPort: 7002,
            oscIncomingPort: 9002
        )

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tourmix-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("config.json")

        try config.save(to: fileURL)
        let loaded = AppConfiguration.load(from: fileURL)

        #expect(loaded == config)
        let bound = loaded.profiles[1].boundOutputChannels
        #expect(bound.map(\.channelIndex) == [0, 6])
        #expect(bound.map(\.safetyClamp0dB) == [true, false])
    }

    @Test("CoordinatorEngine 消费模拟 Knob 步进驱动 TotalMix 输出通道 0 调音、忽略 0xC4 停止码并触发 0dB LOCK HUD")
    @MainActor
    func coordinatorDrivesOutputFaderAndEmitsZeroDbLockHUD() {
        var sentOSC: [OSCMessage] = []
        let mockNow: TimeInterval = 1000.0
        let totalMix = TotalMixController(
            settleSyncDebounceSeconds: 10.0,
            nowProvider: { mockNow },
            sendHandler: { sentOSC.append($0) }
        )

        // 先让 TotalMix 确认 AN 1/2 当前在 -0.3 dB
        totalMix.handleIncomingMessage(.float("/output/0/volume", Float(-0.3)), timestamp: mockNow)
        sentOSC.removeAll()

        let engine = CoordinatorEngine(
            configuration: .factoryDefault,
            persistChangesToDisk: false,
            totalMix: totalMix
        )

        var capturedHUDEvents: [CoordinatorHUDEvent] = []
        engine.onHUDEvent = { capturedHUDEvents.append($0) }

        // 1. 顺时针拧 1 格 Knob (0x44 -> +0.5 dB 慢速档)，从 -0.3 dB 上推应触发 0.0 dB 安全限位！
        engine.handleDecodedInput(.rotaryStep(.knob, .cw), timestamp: 10.0)
        // 紧跟硬件发送的 0xC4 停止码：必须计 0 步且绝不熄灭 activePhysicalControls 高亮
        engine.handleDecodedInput(.rotaryStop(.knob, .cw), timestamp: 10.002)

        #expect(engine.activePhysicalControls.contains(.knob))
        #expect(sentOSC.count == 1)
        #expect(sentOSC[0].address == "/output/0/faderlin")

        let sentNorm = Double(sentOSC[0].arguments[0].floatValue ?? 0)
        #expect(abs(sentNorm - RMEFaderCurve.zeroDbNormalized) < 1e-5)

        #expect(capturedHUDEvents.count == 1)
        #expect(capturedHUDEvents[0].title == "AN 1/2")
        #expect(capturedHUDEvents[0].dbText == "0.0 dB")
        #expect(capturedHUDEvents[0].hitZeroDbLock == true)
        #expect(capturedHUDEvents[0].badgeText == "0 dB MAX")

        // 2. 按下默认未绑定的其它所有按键（如 Tall / Short / KnobClick），不应发出任何 OSC 包
        sentOSC.removeAll()
        engine.handleDecodedInput(.buttonPress(.tall), timestamp: 10.1)
        engine.handleDecodedInput(.buttonRelease(.tall), timestamp: 10.2)
        engine.handleDecodedInput(.buttonPress(.knobClick), timestamp: 10.3)
        engine.handleDecodedInput(.buttonRelease(.knobClick), timestamp: 10.4)
        #expect(sentOSC.isEmpty)

        engine.stop()
    }
}
