import Foundation
import Testing
@testable import TourMixCore

@MainActor
private final class MockClock {
    var now: TimeInterval

    init(_ initial: TimeInterval) {
        self.now = initial
    }
}

@Suite("TotalMixController 状态机、冷启动保护、立体声奇偶过滤与 XML 自检测试")
struct TotalMixControllerTests {
    @Test("FirefaceUCXProfile 默认 18 进 / 18 出通道与立体声合并命名准确")
    func firefaceUCXProfileDefaults() {
        let inputs = FirefaceUCXProfile.defaultChannels(for: .input, defaultStereo: true)
        let outputs = FirefaceUCXProfile.defaultChannels(for: .output, defaultStereo: true)

        #expect(inputs.count == 18)
        #expect(outputs.count == 18)

        let visibleOutputs = outputs.filter { !$0.isHiddenPartner }
        #expect(visibleOutputs.map(\.index) == [0, 2, 4, 6, 8, 10, 12, 14, 16])
        #expect(visibleOutputs.map(\.displayName) == [
            "AN 1/2", "AN 3/4", "AN 5/6", "PH 7/8",
            "SPDIF L/R", "ADAT 1/2", "ADAT 3/4", "ADAT 5/6", "ADAT 7/8",
        ])

        // TotalMix 返回单声道默认名 "AN 1" 或空字符串 "" 时，立体声态仍合并展示为 "AN 1/2"
        #expect(
            FirefaceUCXProfile.resolveDisplayName(bus: .output, index: 0, rawName: "AN 1", isStereo: true) == "AN 1/2"
        )
        #expect(
            FirefaceUCXProfile.resolveDisplayName(bus: .output, index: 6, rawName: "PH 7", isStereo: true) == "PH 7/8"
        )
        // 用户自定义名称保留原样
        #expect(
            FirefaceUCXProfile.resolveDisplayName(bus: .output, index: 0, rawName: "Main Genelec", isStereo: true) == "Main Genelec"
        )
    }

    @Test("首次收到合法 Global OSC 包立即置 isConnected = true 并请求 /sendall 2.0f")
    @MainActor
    func initialHandshakeSendsSendAll2() {
        var sentMessages: [OSCMessage] = []
        let controller = TotalMixController(
            settleSyncDebounceSeconds: 0.0,
            sendHandler: { sentMessages.append($0) }
        )

        #expect(controller.isConnected == false)

        controller.handleIncomingMessage(.string("/status/device", "Fireface UCX (23908219)"))

        #expect(controller.isConnected == true)
        #expect(controller.detectedDeviceName == "Fireface UCX (23908219)")
        #expect(sentMessages == [.float("/sendall", Float(2.0))])
    }

    @Test("冷启动防跳变保护：未收到初始音量前拧旋钮仅暂存增量并发 /sendchan，拿到真值后平滑叠加")
    @MainActor
    func coldStartAntiJumpProtection() {
        var sentMessages: [OSCMessage] = []
        let clock = MockClock(100.0)
        let controller = TotalMixController(
            settleSyncDebounceSeconds: 10.0, // 避免本用例立即触发防抖尾部
            nowProvider: { clock.now },
            sendHandler: { sentMessages.append($0) }
        )

        // 先完成在线握手
        controller.handleIncomingMessage(.string("/status/device", "Fireface UCX"), timestamp: clock.now)
        sentMessages.removeAll()

        // 此时通道 0 (AN 1/2) 尚未收到 /output/0/volume，hasConfirmedValue == false
        #expect(controller.outputChannels[0].hasConfirmedValue == false)

        // 连续拧两格：+1.0 dB 与 +1.5 dB（累计 +2.5 dB）
        let step1 = controller.adjustOutputFaderDb(channel: 0, deltaDb: 1.0, safetyClamp0dB: true)
        clock.now += 0.010
        let step2 = controller.adjustOutputFaderDb(channel: 0, deltaDb: 1.5, safetyClamp0dB: true)

        #expect(step1.isDeferredColdStart == true)
        #expect(step2.isDeferredColdStart == true)
        // 绝不能盲目发送 /output/0/faderlin！只能发送一次 /sendchan/output/0 1.0f
        #expect(sentMessages == [.float("/sendchan/output/0", Float(1.0))])

        // 3ms 后收到 TotalMix 权威回包 /output/0/volume -20.0 dB
        clock.now += 0.003
        sentMessages.removeAll()
        controller.handleIncomingMessage(.float("/output/0/volume", Float(-20.0)), timestamp: clock.now)

        // 应立即基于 -20.0 dB 叠加 +2.5 dB -> -17.5 dB，并发送 /output/0/faderlin
        #expect(controller.outputChannels[0].hasConfirmedValue == true)
        #expect(abs(controller.outputChannels[0].dbValue - (-17.5)) < 0.05)
        #expect(controller.outputChannels[0].formattedDb == "-17.5 dB")
        #expect(sentMessages.count == 1)
        #expect(sentMessages[0].address == "/output/0/faderlin")

        let expectedNorm = Float(RMEFaderCurve.dbToNormalized(-17.5))
        let actualNorm = sentMessages[0].arguments.first?.floatValue ?? -1
        #expect(abs(actualNorm - expectedNorm) < 1e-4)

        controller.stop()
    }

    @Test("立体声奇偶通道保护：对奇数右声道操作自动归并至偶数左声道 2k，且支持 0.0 dB 安全限位")
    @MainActor
    func stereoEvenChannelRoutingAndZeroDbSafetyClamp() {
        var sentMessages: [OSCMessage] = []
        let mockNow: TimeInterval = 200.0
        let controller = TotalMixController(
            settleSyncDebounceSeconds: 10.0,
            nowProvider: { mockNow },
            sendHandler: { sentMessages.append($0) }
        )

        // 确认 AN 1/2 当前在 -1.0 dB
        controller.handleIncomingMessage(.float("/output/0/volume", Float(-1.0)), timestamp: mockNow)
        sentMessages.removeAll()

        // 故意传入奇数右声道索引 1，且顺时针拧 +2.5 dB（应归并到通道 0 并被 0.0 dB 锁钳位）
        let result = controller.adjustOutputFaderDb(channel: 1, deltaDb: 2.5, safetyClamp0dB: true)
        #expect(result.channelIndex == 0)
        #expect(result.hitZeroDbLock == true)
        #expect(abs(result.dbValue - 0.0) < 0.001)
        #expect(result.formattedDb == "0.0 dB")

        #expect(sentMessages.count == 1)
        #expect(sentMessages[0].address == "/output/0/faderlin")
        let sentNorm = Double(sentMessages[0].arguments[0].floatValue ?? 0)
        #expect(abs(sentNorm - RMEFaderCurve.zeroDbNormalized) < 1e-5)

        // 对奇数通道 1 切换静音同样只发 /output/0/mute
        sentMessages.removeAll()
        let muted = controller.toggleOutputMute(channel: 1)
        #expect(muted == true)
        #expect(sentMessages == [.float("/output/0/mute", Float(1.0))])

        // 当 TotalMix 切换为单声道 (/output/0/stereo 0.0) 时，通道 1 解除隐藏
        controller.handleIncomingMessage(.float("/output/0/stereo", Float(0.0)), timestamp: mockNow)
        #expect(controller.outputChannels[0].isStereo == false)
        #expect(controller.outputChannels[1].isHiddenPartner == false)
        #expect(controller.visibleOutputChannels.contains(where: { $0.index == 1 }))

        controller.stop()
    }

    @Test("220ms 乐观窗口抑制滞后回包且到期不回滚 + 停手防抖触发 /sendchan 定音同步")
    @MainActor
    func optimisticWindowAndSettleSync() async throws {
        var sentMessages: [OSCMessage] = []
        let clock = MockClock(500.0)
        let controller = TotalMixController(
            optimisticWindowSeconds: 0.220,
            settleSyncDebounceSeconds: 0.045, // 缩短防抖等待以便单测极速验证
            nowProvider: { clock.now },
            sendHandler: { sentMessages.append($0) }
        )

        // 初始音量 -300.0 dB (-∞ dB)
        controller.handleIncomingMessage(.float("/output/0/volume", Float(-300.0)), timestamp: clock.now)
        #expect(controller.outputChannels[0].normalizedFader == 0.0)
        #expect(controller.outputChannels[0].formattedDb == "-∞ dB")
        sentMessages.removeAll()

        // 设置到 -10.0 dB
        _ = controller.setOutputFaderDb(channel: 0, db: -10.0)
        #expect(abs(controller.outputChannels[0].dbValue - (-10.0)) < 0.05)

        // 100ms 时（仍在 220ms 乐观窗口内）收到旧回包 -25.0 dB，必须被抑制不回跳！
        clock.now += 0.100
        controller.handleIncomingMessage(.float("/output/0/volume", Float(-25.0)), timestamp: clock.now)
        #expect(abs(controller.outputChannels[0].dbValue - (-10.0)) < 0.05)

        // 推进超过 220ms 乐观窗口，即使没有新回包也绝不回滚状态
        clock.now += 0.150
        #expect(abs(controller.outputChannels[0].dbValue - (-10.0)) < 0.05)

        // 等待停手定音防抖协程触发 /sendchan/output/0 1.0f
        try await Task.sleep(for: .milliseconds(80))
        #expect(sentMessages.contains(.float("/sendchan/output/0", Float(1.0))))

        // 定音回包到达后权威对齐为 -9.8 dB
        controller.handleIncomingMessage(.float("/output/0/volume", Float(-9.8)), timestamp: clock.now)
        #expect(abs(controller.outputChannels[0].dbValue - (-9.8)) < 0.05)

        controller.stop()
    }

    @Test("监听室开关、快照 (1...8)、布局上限 (1...6)、窗口显隐与离线无头多根 XML 解析")
    @MainActor
    func controlRoomSnapshotsLayoutsAndXMLInspector() {
        var sentMessages: [OSCMessage] = []
        let controller = TotalMixController(
            settleSyncDebounceSeconds: 0.0,
            sendHandler: { sentMessages.append($0) }
        )

        _ = controller.toggleControlRoom(.dim)
        _ = controller.toggleControlRoom(.mono)
        _ = controller.toggleControlRoom(.speakerB)
        _ = controller.toggleControlRoom(.talkback)
        _ = controller.toggleControlRoom(.globalMute)

        controller.loadSnapshot(0) // 非法 0，应忽略
        controller.loadSnapshot(9) // 越界 9，应忽略
        controller.loadSnapshot(3) // 合法 1-based

        controller.loadLayout(0)   // 非法 0，应忽略
        controller.loadLayout(7)   // 超过上限 6，应忽略
        controller.loadLayout(6)   // 合法上限 6

        _ = controller.toggleTotalMixWindow() // 默认 true -> false -> /showwindow 0.0f

        #expect(sentMessages == [
            .float("/controlroom/dim", Float(1.0)),
            .float("/controlroom/mainmono", Float(1.0)),
            .float("/controlroom/speakerb", Float(1.0)),
            .float("/controlroom/talkback", Float(1.0)),
            .float("/globalmute", Float(1.0)),
            .float("/snapshot/load/3", Float(1.0)),
            .float("/layout/load/6", Float(1.0)),
            .float("/showwindow", Float(0.0)),
        ])

        // 验证无 <?xml?> 头 + 双根标签 (<FirefaceUCX...><Frame0>) + "6.00,..." 浮点属性的 XML 解析
        let sampleXML = """
        \t<FirefaceUCX23908219>
        \t\t<General>
        \t\t\t<val e="MainChannel" v="6.00,6.00,6.00,6.00,6.00,6.00,6.00,6.00,6.00,"/>
        \t\t\t<val e="OSCEnabled" v="1"/>
        \t\t</General>
        \t\t<OscRemote0>
        \t\t\t<val e="OSCRemoteInUse" v="1"/>
        \t\t\t<val e="OSCOwnPort" v="7001"/>
        \t\t\t<val e="OSCRemotePort" v="9001"/>
        \t\t\t<val e="OSCRemoteHost" v="127.0.0.1"/>
        \t\t\t<val e="OSCCompatibility" v="2"/>
        \t\t</OscRemote0>
        \t</FirefaceUCX23908219>
        \t<Frame0>
        \t\t<Cache0>
        \t\t\t<val e="DeviceName" v="Fireface UCX (23908219)"/>
        \t\t</Cache0>
        \t</Frame0>
        """

        let diagReady = TotalMixConfigInspector.parseXMLData(Data(sampleXML.utf8))
        #expect(diagReady.isSnapshotConfiguredForGlobalOSC == true)
        #expect(diagReady.oscMasterEnabled == true)
        #expect(diagReady.mainChannelIndex == 6)
        #expect(diagReady.mainChannelDisplayName == "PH 7/8")
        #expect(diagReady.deviceName == "Fireface UCX (23908219)")
        #expect(diagReady.matchedRemote?.compatibility == .globalOSC)

        // 当 OSCCompatibility 为 0 (1.90) 且地址为空时准确识别问题项
        let legacyXML = sampleXML
            .replacingOccurrences(of: "<val e=\"OSCCompatibility\" v=\"2\"/>", with: "<val e=\"OSCCompatibility\" v=\"0\"/>")
            .replacingOccurrences(of: "127.0.0.1", with: "")
        let diagLegacy = TotalMixConfigInspector.parseXMLData(Data(legacyXML.utf8))
        #expect(diagLegacy.isSnapshotConfiguredForGlobalOSC == false)
        #expect(diagLegacy.issues.contains(.compatibilityNotGlobalOSC(slotNumber: 1, current: .legacy190)))
        #expect(diagLegacy.issues.contains(.remoteHostEmptyOrNonLocal(slotNumber: 1, currentHost: "")))
    }
}
