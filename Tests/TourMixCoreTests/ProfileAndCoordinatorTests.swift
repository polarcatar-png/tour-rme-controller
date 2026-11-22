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

    @Test("向后兼容旧版 config.json（缺省 safetyMaxDb 字段 + mouseScroll _0 键）无损解码")
    func legacyConfigJsonDecodesWithoutDataLoss() throws {
        let legacyJSON = """
        {
          "activeProfileId" : "00000000-0000-0000-0000-000000000001",
          "autoSwitchByFrontmostApp" : true,
          "oscHost" : "127.0.0.1",
          "oscIncomingPort" : 9001,
          "oscOutgoingPort" : 7001,
          "profiles" : [
            {
              "buttonBindings" : [
                "tall",
                {
                  "keyShortcut" : {
                    "_0" : {
                      "command" : false,
                      "control" : false,
                      "displayLabel" : "↩",
                      "keyCode" : 36,
                      "option" : false,
                      "shift" : false
                    }
                  }
                }
              ],
              "buttonComboBindings" : [],
              "doublePressBindings" : [],
              "id" : "00000000-0000-0000-0000-000000000001",
              "modifierButtons" : [],
              "name" : "默认监听 (AN 1\\/2)",
              "rotaryBindings" : [
                "scroll",
                {
                  "mouseScroll" : {
                    "_0" : {
                      "axis" : "vertical",
                      "dynamicAcceleration" : true,
                      "invertDirection" : false,
                      "mode" : "mouseWheelLine",
                      "speed" : 3
                    }
                  }
                },
                "knob",
                {
                  "rmeOutputFader" : {
                    "ballistics" : {
                      "fastStepDb" : 2.5,
                      "fastThresholdSec" : 0.045,
                      "mediumStepDb" : 1,
                      "mode" : { "dynamic" : {} },
                      "slowStepDb" : 0.2,
                      "slowThresholdSec" : 0.11
                    },
                    "channelIndex" : 0,
                    "safetyClamp0dB" : true
                  }
                }
              ],
              "rotaryComboBindings" : []
            }
          ],
          "showDbInMenuBar" : false,
          "showHUD" : true
        }
        """

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tourmix-legacy-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("config.json")
        try Data(legacyJSON.utf8).write(to: fileURL)

        let loaded = AppConfiguration.load(from: fileURL)
        #expect(loaded.profiles.count == 1)
        let profile = loaded.profiles[0]
        #expect(profile.buttonBindings[.tall] == .keyShortcut(KeyCombo(keyCode: 0x24, displayLabel: "↩")))
        #expect(
            profile.rotaryBindings[.scroll] == .mouseScroll(
                MouseScrollConfig(mode: .mouseWheelLine, axis: .vertical, speed: 3)
            )
        )
        #expect(
            profile.rotaryBindings[.knob] == .rmeOutputFader(
                channelIndex: 0,
                ballistics: .fine,
                safetyClamp0dB: true,
                safetyMaxDb: 0.0
            )
        )
    }

    @Test("自定义 safetyMaxDb Codable 往返、切换开关保留原上限与 HUD 动态上限徽章")
    @MainActor
    func customSafetyLimitRoundTripAndHUD() throws {
        var customProfile = ProfileConfig.factoryDefault
        customProfile.rotaryBindings[.knob] = .rmeOutputFader(
            channelIndex: 0,
            ballistics: .standard,
            safetyClamp0dB: true,
            safetyMaxDb: -12.5
        )
        customProfile.rotaryComboBindings[.init(modifier: .tour, rotary: .knob)] = .rmeSubmixFader(
            sourceBus: .playback,
            sourceIndex: 0,
            outputIndex: 6,
            ballistics: .fine,
            safetyClamp0dB: true,
            safetyMaxDb: -6.0
        )

        let config = AppConfiguration(
            profiles: [customProfile],
            activeProfileId: customProfile.id
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)
        #expect(decoded == config)

        let mockNow: TimeInterval = 2000.0
        let totalMix = TotalMixController(
            settleSyncDebounceSeconds: 10.0,
            nowProvider: { mockNow },
            sendHandler: { _ in }
        )
        totalMix.handleIncomingMessage(.float("/output/0/volume", Float(-13.0)), timestamp: mockNow)

        let engine = CoordinatorEngine(
            configuration: config,
            persistChangesToDisk: false,
            totalMix: totalMix
        )

        // 切换保护开关关闭再打开：保留自定义上限 (-12.5 dB -> 后改为 -12.0 dB 测试 HUD)
        engine.setOutputChannelSafetyClamp(channelIndex: 0, enabled: false)
        #expect(engine.boundOutputChannels.first?.safetyClamp0dB == false)
        #expect(engine.boundOutputChannels.first?.safetyMaxDb == -12.5)

        engine.setOutputChannelSafetyLimit(channelIndex: 0, enabled: true, maxDb: -12.0)
        #expect(engine.boundOutputChannels.first?.safetyClamp0dB == true)
        #expect(engine.boundOutputChannels.first?.safetyMaxDb == -12.0)

        var hudEvents: [CoordinatorHUDEvent] = []
        engine.onHUDEvent = { hudEvents.append($0) }

        // 从 -13.0 dB 上拧 2 格触发快速加速越过 -12.0 dB
        engine.handleDecodedInput(.rotaryStep(.knob, .cw), timestamp: 20.0)
        engine.handleDecodedInput(.rotaryStep(.knob, .cw), timestamp: 20.015)

        let lastHUD = hudEvents.last
        #expect(lastHUD?.hitZeroDbLock == true)
        #expect(lastHUD?.badgeText == "-12 dB MAX")
        #expect(lastHUD?.dbText == "-12.0 dB")
        let expectedLimitPos = RMEFaderCurve.dbToNormalized(-12.0)
        #expect(abs((lastHUD?.safetyLimitNormalizedPosition ?? -1) - expectedLimitPos) < 1e-6)

        engine.stop()
    }

    @Test("冷启动首次旋钮增量在收到 TotalMix 回包落地时自动补弹 HUD（含自定义上限徽章）")
    @MainActor
    func coldStartDeferredReplayEmitsHUD() {
        var sentOSC: [OSCMessage] = []
        let mockNow: TimeInterval = 3000.0
        let totalMix = TotalMixController(
            settleSyncDebounceSeconds: 10.0,
            nowProvider: { mockNow },
            sendHandler: { sentOSC.append($0) }
        )

        var profile = ProfileConfig.factoryDefault
        profile.rotaryBindings[.knob] = .rmeOutputFader(
            channelIndex: 0,
            ballistics: .standard,
            safetyClamp0dB: true,
            safetyMaxDb: -12.0
        )
        let config = AppConfiguration(
            profiles: [profile],
            activeProfileId: profile.id
        )

        let engine = CoordinatorEngine(
            configuration: config,
            persistChangesToDisk: false,
            totalMix: totalMix
        )

        var hudEvents: [CoordinatorHUDEvent] = []
        engine.onHUDEvent = { hudEvents.append($0) }

        // 1. 通道 0 尚未确认初始音量，先拧一格 +0.5 dB（触发 /sendchan/output/0 且暂存增量）
        engine.handleDecodedInput(.rotaryStep(.knob, .cw), timestamp: 30.0)
        #expect(hudEvents.isEmpty)
        #expect(sentOSC.contains(.float("/sendchan/output/0", Float(1.0))))

        // 2. TotalMix 返回当前音量 -12.2 dB -> 叠加 +0.5 dB 被 -12.0 dB 上限钳位，并立即补弹 HUD！
        totalMix.handleIncomingMessage(.float("/output/0/volume", Float(-12.2)), timestamp: mockNow)

        #expect(hudEvents.count == 1)
        #expect(hudEvents[0].title == "AN 1/2")
        #expect(hudEvents[0].dbText == "-12.0 dB")
        #expect(hudEvents[0].hitZeroDbLock == true)
        #expect(hudEvents[0].badgeText == "-12 dB MAX")

        let expectedLimitPos = RMEFaderCurve.dbToNormalized(-12.0)
        #expect(abs((hudEvents[0].safetyLimitNormalizedPosition ?? -1) - expectedLimitPos) < 1e-6)

        engine.stop()
    }
}
