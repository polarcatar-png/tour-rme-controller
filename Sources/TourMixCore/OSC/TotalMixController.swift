import Foundation
import Observation

/// OSC 收发诊断日志条目（供 `DiagnosticsView` 实时监控使用）。
public struct OSCDiagnosticEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let direction: String
    public let summary: String
    public let timestamp: TimeInterval

    public init(
        id: UUID = UUID(),
        direction: String,
        summary: String,
        timestamp: TimeInterval
    ) {
        self.id = id
        self.direction = direction
        self.summary = summary
        self.timestamp = timestamp
    }
}

/// RME TotalMix FX 2.10 `Global OSC` 双向状态引擎。
///
/// 核心机制（对齐 `#7` 二进制反汇编核查结论）：
/// 1. **实时 UDP 唯一在线判据**：启动及每 `3.0 s` 发送 `/sendstate 1.0f`；首次收到任何合法 Global OSC 包立即标记
///    `isConnected = true` 并发送 `/sendall 2.0f` 拉取全局设置与活跃混音节点；离线 XML 快照仅在超时未连通时作辅助提示。
/// 2. **双制式推子反馈兼容**：同时支持默认 `/output/{ch}/volume <dB>`（含 `-300.0 dB` 极值）与线性 `/output/{ch}/faderlin <0..1>`，
///    以及子混音 `/mix/{in|pb}/{src}/{out}/{fader|faderlin}`。
/// 3. **立体声奇偶通道保护**：当偶数通道 `2k` 为立体声合并态（`isStereo == true`）时，奇数通道 `2k+1` 标记 `isHiddenPartner = true`，
///    所有控制命令仅向偶数左通道 `2k` 发送（防止命中 TotalMix 奇数通道静默丢弃分支）。
/// 4. **冷启动防跳变保护**：`hasConfirmedValue == false` 时拧动旋钮绝不盲目发送默认绝对值，而是暂存 `pendingDeltaDb`
///    并立即触发 `/sendchan/output/{ch} 1.0f`，收到真实音量瞬间无缝叠加增量。
/// 5. **220 ms 乐观窗口 + 250 ms 停手定音同步**：旋转期间抑制滞后旧回包防抖动，窗口到期绝不回滚（兼容默认 `Re-send received = OFF`），
///    停手 `250 ms` 防抖后发送 `/sendchan/output/{ch} 1.0f` 强制拉取 TotalMix 权威状态完成最终对齐。
@MainActor
@Observable
public final class TotalMixController {
    // MARK: - Public Observable State

    /// 当前是否已通过实时 UDP 与 TotalMix Global OSC 建立双向通信。
    public private(set) var isConnected: Bool = false

    /// 语义别名（方便 UI 层直接读取 `oscConnected`）。
    public var oscConnected: Bool { isConnected }

    /// 底层 UDP 监听套接字状态（含 `EADDRINUSE` 端口冲突信息）。
    public private(set) var transportState: OSCTransportState = .stopped

    public private(set) var host: String
    public private(set) var outgoingPort: UInt16
    public private(set) var incomingPort: UInt16

    /// TotalMix 上报的硬件设备名（例如 `"Fireface UCX (23908219)"`）。
    public private(set) var detectedDeviceName: String = FirefaceUCXProfile.deviceLabel

    /// DSP 负载百分比（若硬件支持）。
    public private(set) var dspLoad: Double?

    /// 最近一次收到合法 OSC 消息的系统运行时间戳（不触发 SwiftUI 视图刷新）。
    @ObservationIgnored
    public private(set) var lastMessageTimestamp: TimeInterval?

    /// 18+ 路硬件输入通道状态（`0-based`）。
    public private(set) var inputChannels: [MixerChannelState]

    /// 18+ 路软件回放通道状态（`0-based`）。
    public private(set) var playbackChannels: [MixerChannelState]

    /// 18+ 路硬件输出通道状态（`0-based`）。
    public private(set) var outputChannels: [MixerChannelState]

    /// 活跃子混音路由状态表。
    public private(set) var submixRoutes: [SubmixRouteKey: SubmixRouteState] = [:]

    /// Control Room 监听室与全局状态。
    public private(set) var controlRoom: ControlRoomState = ControlRoomState()

    /// 仅当 UDP 探测超时（`!isConnected`）时提供的离线 XML 快照辅助诊断信息。
    public private(set) var offlineDiagnostic: TotalMixConfigDiagnostic?

    /// TotalMix 主窗口显隐估计状态（用于 `/showwindow` 切换）。
    public private(set) var isTotalMixWindowVisible: Bool = true

    /// 是否按需采集 OSC 收发报文诊断日志（仅诊断面板打开时开启，平时保持关闭以降低后台堆分配）。
    @ObservationIgnored
    public private(set) var isDiagnosticsCaptureEnabled: Bool = false

    /// 最近收发的 OSC 报文诊断环形缓冲（最多保留 120 条）。
    public private(set) var recentDiagnostics: [OSCDiagnosticEntry] = []

    // MARK: - Timing Configuration

    public let heartbeatIntervalSeconds: Double
    public let idleConnectedHeartbeatIntervalSeconds: Double
    public let offlineProbeTimeoutSeconds: Double
    public let optimisticWindowSeconds: Double
    public let settleSyncDebounceSeconds: Double
    public let staleConnectionTimeoutSeconds: Double

    // MARK: - Computed Channel Collections

    /// 过滤掉立体声奇数右声道配对槽与隐藏通道（`color == 0`）后的可见硬件输入通道。
    public var visibleInputChannels: [MixerChannelState] {
        inputChannels.filter { !$0.isHiddenPartner && $0.color != 0 }
    }

    /// 过滤掉立体声奇数右声道配对槽与隐藏通道后的可见软件回放通道。
    public var visiblePlaybackChannels: [MixerChannelState] {
        playbackChannels.filter { !$0.isHiddenPartner && $0.color != 0 }
    }

    /// 过滤掉立体声奇数右声道配对槽与隐藏通道后的可见硬件输出通道。
    public var visibleOutputChannels: [MixerChannelState] {
        outputChannels.filter { !$0.isHiddenPartner && $0.color != 0 }
    }

    /// 当前 Control Room `Main Out` 通道的可读名称（例如 `"PH 7/8"` 或 `"AN 1/2"`）。
    public var mainOutDisplayName: String {
        let idx = canonicalOutputIndex(controlRoom.mainOutChannelIndex)
        if outputChannels.indices.contains(idx) {
            return outputChannels[idx].displayName
        }
        return FirefaceUCXProfile.stereoDefaultLabel(bus: .output, evenIndex: idx)
    }

    /// 当冷启动暂存的旋钮增量在收到 TotalMix 首次权威音量回包后落地发送时触发（供 HUD 补弹反馈）。
    @ObservationIgnored
    public var onDeferredOutputFaderApplied: ((FaderStepResult) -> Void)?

    // MARK: - Private State

    private struct PendingColdStartAdjustment {
        var deltaDb: Double
        var safetyClamp0dB: Bool
        var safetyMaxDb: Double
        var lastQueryTimestamp: TimeInterval
    }

    private struct OptimisticFaderGuard {
        var normalizedValue: Double
        var expiresAt: TimeInterval
    }

    private static let maxChannelIndexLimit = 256
    private static let maxDiagnosticEntries = 120

    private nonisolated let transport: OSCUDPTransport?
    private let customSendHandler: (@MainActor (OSCMessage) -> Void)?
    private let nowProvider: @MainActor () -> TimeInterval
    private let configDirectoryURL: URL?

    private var hasInitialSyncCompleted: Bool = false
    private var hasReceivedMainOutFromOSC: Bool = false

    private var pendingColdStartAdjustments: [Int: PendingColdStartAdjustment] = [:]
    private var optimisticOutputs: [Int: OptimisticFaderGuard] = [:]
    private var settleSyncTasks: [Int: Task<Void, Never>] = [:]

    private var inboundConsumerTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var offlineProbeTask: Task<Void, Never>?

    // MARK: - Initializers

    /// 生产环境构造器：内部持有单套接字 `OSCUDPTransport`（默认 `127.0.0.1`, 发送 `7001`, 接收 `9001`）。
    public init(
        host: String = "127.0.0.1",
        outgoingPort: UInt16 = 7001,
        incomingPort: UInt16 = 9001,
        configDirectoryURL: URL? = nil,
        heartbeatIntervalSeconds: Double = 3.0,
        idleConnectedHeartbeatIntervalSeconds: Double = 10.0,
        offlineProbeTimeoutSeconds: Double = 1.2,
        optimisticWindowSeconds: Double = 0.220,
        settleSyncDebounceSeconds: Double = 0.250,
        staleConnectionTimeoutSeconds: Double = 25.0
    ) {
        self.host = host
        self.outgoingPort = outgoingPort
        self.incomingPort = incomingPort
        self.configDirectoryURL = configDirectoryURL
        self.heartbeatIntervalSeconds = heartbeatIntervalSeconds
        self.idleConnectedHeartbeatIntervalSeconds = idleConnectedHeartbeatIntervalSeconds
        self.offlineProbeTimeoutSeconds = offlineProbeTimeoutSeconds
        self.optimisticWindowSeconds = optimisticWindowSeconds
        self.settleSyncDebounceSeconds = settleSyncDebounceSeconds
        self.staleConnectionTimeoutSeconds = staleConnectionTimeoutSeconds
        self.transport = OSCUDPTransport(
            host: host,
            outgoingPort: outgoingPort,
            incomingPort: incomingPort
        )
        self.customSendHandler = nil
        self.nowProvider = { ProcessInfo.processInfo.systemUptime }

        self.inputChannels = FirefaceUCXProfile.defaultChannels(for: .input, defaultStereo: true)
        self.playbackChannels = FirefaceUCXProfile.defaultChannels(for: .playback, defaultStereo: true)
        self.outputChannels = FirefaceUCXProfile.defaultChannels(for: .output, defaultStereo: true)
    }

    /// 单元测试与依赖注入构造器：支持注入自定义消息发送闭包、可控时钟及防抖时长。
    public init(
        host: String = "127.0.0.1",
        outgoingPort: UInt16 = 7001,
        incomingPort: UInt16 = 9001,
        configDirectoryURL: URL? = nil,
        heartbeatIntervalSeconds: Double = 3.0,
        idleConnectedHeartbeatIntervalSeconds: Double = 10.0,
        offlineProbeTimeoutSeconds: Double = 1.2,
        optimisticWindowSeconds: Double = 0.220,
        settleSyncDebounceSeconds: Double = 0.250,
        staleConnectionTimeoutSeconds: Double = 25.0,
        nowProvider: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sendHandler: @escaping @MainActor (OSCMessage) -> Void
    ) {
        self.host = host
        self.outgoingPort = outgoingPort
        self.incomingPort = incomingPort
        self.configDirectoryURL = configDirectoryURL
        self.heartbeatIntervalSeconds = heartbeatIntervalSeconds
        self.idleConnectedHeartbeatIntervalSeconds = idleConnectedHeartbeatIntervalSeconds
        self.offlineProbeTimeoutSeconds = offlineProbeTimeoutSeconds
        self.optimisticWindowSeconds = optimisticWindowSeconds
        self.settleSyncDebounceSeconds = settleSyncDebounceSeconds
        self.staleConnectionTimeoutSeconds = staleConnectionTimeoutSeconds
        self.transport = nil
        self.customSendHandler = sendHandler
        self.nowProvider = nowProvider

        self.inputChannels = FirefaceUCXProfile.defaultChannels(for: .input, defaultStereo: true)
        self.playbackChannels = FirefaceUCXProfile.defaultChannels(for: .playback, defaultStereo: true)
        self.outputChannels = FirefaceUCXProfile.defaultChannels(for: .output, defaultStereo: true)
    }

    deinit {
        transport?.stop()
    }

    // MARK: - Lifecycle & Transport Control

    /// 启动 OSC 监听、立即发送首帧 `/sendstate 1.0f`，并开启自适应周期心跳（断线探测 `3s` / 在线稳态 `10s`）与离线诊断超时检查。
    public func start() {
        stopBackgroundTasks()

        if let transport {
            transport.start()
            let stream = transport.events
            inboundConsumerTask = Task { [weak self] in
                for await event in stream {
                    guard !Task.isCancelled, let self else { break }
                    self.handleTransportEvent(event)
                }
            }
        } else {
            let listeningState = OSCTransportState.listening(
                localHost: "127.0.0.1",
                incomingPort: incomingPort,
                remoteHost: host,
                outgoingPort: outgoingPort
            )
            if transportState != listeningState {
                transportState = listeningState
            }
        }

        // 启动时立即探测一次状态
        requestStateHeartbeat()
        scheduleOfflineProbeCheck()

        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let interval = self.isConnected
                    ? max(self.heartbeatIntervalSeconds, self.idleConnectedHeartbeatIntervalSeconds)
                    : max(0.1, self.heartbeatIntervalSeconds)
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                self.performHeartbeatTick()
            }
        }
    }

    /// 停止所有后台任务与底层 UDP 监听。
    public func stop() {
        stopBackgroundTasks()
        for (_, task) in settleSyncTasks {
            task.cancel()
        }
        settleSyncTasks.removeAll()
        pendingColdStartAdjustments.removeAll()
        optimisticOutputs.removeAll()

        transport?.stop()
        transportState = .stopped
        isConnected = false
        hasInitialSyncCompleted = false
    }

    /// 动态修改 OSC 目标地址与收发端口，立即重绑套接字并重新握手。
    public func reconfigureTransport(
        host: String,
        outgoingPort: UInt16,
        incomingPort: UInt16
    ) {
        self.host = host
        self.outgoingPort = outgoingPort
        self.incomingPort = incomingPort
        self.isConnected = false
        self.hasInitialSyncCompleted = false
        self.offlineDiagnostic = nil
        self.pendingColdStartAdjustments.removeAll()
        self.optimisticOutputs.removeAll()

        if let transport {
            transport.reconfigure(host: host, outgoingPort: outgoingPort, incomingPort: incomingPort)
        } else {
            transportState = .listening(
                localHost: "127.0.0.1",
                incomingPort: incomingPort,
                remoteHost: host,
                outgoingPort: outgoingPort
            )
        }

        requestStateHeartbeat()
        scheduleOfflineProbeCheck()
    }

    /// 执行单次心跳检查并发送 `/sendstate 1.0f`（亦可供测试同步调用）。
    public func performHeartbeatTick() {
        let now = nowProvider()
        if isConnected,
           let lastSeen = lastMessageTimestamp,
           now - lastSeen > staleConnectionTimeoutSeconds
        {
            isConnected = false
            hasInitialSyncCompleted = false
            refreshOfflineDiagnostic()
        }
        requestStateHeartbeat()
    }

    /// 手动刷新离线 XML 诊断信息（仅在 `!isConnected` 时保留结果）。
    public func refreshOfflineDiagnostic() {
        guard !isConnected else {
            if offlineDiagnostic != nil {
                offlineDiagnostic = nil
            }
            return
        }
        let diag = TotalMixConfigInspector.inspect(
            directoryURL: configDirectoryURL,
            expectedOutgoingPort: outgoingPort,
            expectedIncomingPort: incomingPort
        )
        if offlineDiagnostic != diag {
            offlineDiagnostic = diag
        }
        if !hasReceivedMainOutFromOSC,
           let xmlMainOut = diag.mainChannelIndex,
           controlRoom.mainOutChannelIndex != xmlMainOut
        {
            controlRoom.mainOutChannelIndex = xmlMainOut
        }
    }

    /// 开关 OSC 报文实时诊断日志采集；关闭时立即释放缓冲。
    public func setDiagnosticsCaptureEnabled(_ enabled: Bool) {
        isDiagnosticsCaptureEnabled = enabled
        if !enabled && !recentDiagnostics.isEmpty {
            recentDiagnostics.removeAll(keepingCapacity: false)
        }
    }

    // MARK: - Queries & Helpers

    /// 返回指定总线的可见通道列表（已过滤立体声奇数隐藏通道与 `color == 0` 通道）。
    public func visibleChannels(for bus: MixerBus) -> [MixerChannelState] {
        switch bus {
        case .input: return visibleInputChannels
        case .playback: return visiblePlaybackChannels
        case .output: return visibleOutputChannels
        }
    }

    /// 将输出通道索引归并为合法控制索引（若 `2k` 为立体声对，`2k+1` 归并为 `2k`）。
    public func canonicalOutputIndex(_ channel: Int) -> Int {
        let clamped = max(0, channel)
        return FirefaceUCXProfile.canonicalControlIndex(clamped, in: outputChannels)
    }

    /// 获取指定硬件输出通道状态（自动归并立体声右声道索引）。
    public func outputChannel(at channel: Int) -> MixerChannelState? {
        let idx = canonicalOutputIndex(channel)
        guard outputChannels.indices.contains(idx) else { return nil }
        return outputChannels[idx]
    }

    /// 发送 `/sendstate 1.0f`。
    public func requestStateHeartbeat() {
        sendOSC(.float("/sendstate", Float(1.0)))
    }

    /// 发送 `/sendall 2.0f`（仅拉取全局设置与活跃混音节点，不倾泻完整 18x18 矩阵）。
    public func requestFullSync() {
        sendOSC(.float("/sendall", Float(2.0)))
    }

    /// 发送 `/sendchan/{bus}/{ch} 1.0f` 强制拉取单通道权威状态（无视 `Re-send received` 开关）。
    public func requestChannelSync(bus: MixerBus = .output, channel: Int) {
        let targetIndex: Int
        switch bus {
        case .input:
            targetIndex = FirefaceUCXProfile.canonicalControlIndex(max(0, channel), in: inputChannels)
        case .playback:
            targetIndex = FirefaceUCXProfile.canonicalControlIndex(max(0, channel), in: playbackChannels)
        case .output:
            targetIndex = canonicalOutputIndex(channel)
        }
        sendOSC(.float("/sendchan/\(bus.oscChannelSegment)/\(targetIndex)", Float(1.0)))
    }

    // MARK: - Output Fader & Submix Actions

    /// 按相对分贝增量调节指定硬件输出通道音量（旋钮核心入口）。
    ///
    /// - 立体声对自动归并至偶数左声道 `2k`。
    /// - 若 `hasConfirmedValue == false`，启动冷启动保护：累加 `pendingDeltaDb` 并立即请求 `/sendchan/output/{2k} 1.0f`，绝不跳变。
    /// - 若开启 `safetyClamp0dB`，从 `<= safetyMaxDb` 顺时针上推时精准钳位在 `safetyMaxDb` 并返回 `hitZeroDbLock = true`。
    @discardableResult
    public func adjustOutputFaderDb(
        channel: Int,
        deltaDb: Double,
        safetyClamp0dB: Bool = true,
        safetyMaxDb: Double = VolumeSafetyLimit.defaultMaxDb
    ) -> FaderStepResult {
        let rawClamped = min(max(0, channel), Self.maxChannelIndexLimit - 1)
        ensureChannelCapacity(bus: .output, upToIndex: rawClamped)
        let targetIndex = canonicalOutputIndex(rawClamped)
        let currentChannel = outputChannels[targetIndex]
        let now = nowProvider()
        let limitDb = VolumeSafetyLimit.clampCeilingDb(safetyMaxDb)

        // 冷启动防跳变保护：尚未拿到 TotalMix 真实音量前绝不盲发 faderlin
        if !currentChannel.hasConfirmedValue {
            let hadPending = pendingColdStartAdjustments[targetIndex] != nil
            var pending = pendingColdStartAdjustments[targetIndex] ?? PendingColdStartAdjustment(
                deltaDb: 0.0,
                safetyClamp0dB: safetyClamp0dB,
                safetyMaxDb: limitDb,
                lastQueryTimestamp: 0.0
            )
            pending.deltaDb += deltaDb
            pending.safetyClamp0dB = safetyClamp0dB
            pending.safetyMaxDb = limitDb

            if !hadPending || (now - pending.lastQueryTimestamp) >= 0.080 {
                pending.lastQueryTimestamp = now
                pendingColdStartAdjustments[targetIndex] = pending
                sendOSC(.float("/sendchan/output/\(targetIndex)", Float(1.0)))
            } else {
                pendingColdStartAdjustments[targetIndex] = pending
            }

            return FaderStepResult(
                channelIndex: targetIndex,
                displayName: currentChannel.displayName,
                normalizedFader: currentChannel.normalizedFader,
                dbValue: currentChannel.dbValue,
                formattedDb: currentChannel.formattedDb,
                hitZeroDbLock: false,
                safetyMaxDb: safetyClamp0dB ? limitDb : nil,
                isDeferredColdStart: true,
                isMuted: currentChannel.isMuted
            )
        }

        let currentDb = currentChannel.dbValue
        let clamped = applySafetyCeilingClamp(
            currentDb: currentDb,
            deltaDb: deltaDb,
            enabled: safetyClamp0dB,
            maxDb: limitDb
        )
        let targetDb = min(RMEFaderCurve.maxDb, max(RMEFaderCurve.minDb, clamped.targetDb))
        let hitZeroDbLock = clamped.hitLimitLock

        let targetNorm = RMEFaderCurve.dbToNormalized(targetDb)
        return commitOptimisticOutputFader(
            targetIndex: targetIndex,
            normalized: targetNorm,
            hitZeroDbLock: hitZeroDbLock,
            safetyMaxDb: safetyClamp0dB ? limitDb : nil,
            timestamp: now
        )
    }

    /// 直接按归一化值 (`0.0 ... 1.0`) 设置指定硬件输出通道推子（供菜单栏水平推子拖动调用）。
    @discardableResult
    public func setOutputFaderNormalized(
        channel: Int,
        normalized: Double,
        safetyClamp0dB: Bool = false,
        safetyMaxDb: Double = VolumeSafetyLimit.defaultMaxDb
    ) -> FaderStepResult {
        let rawClamped = min(max(0, channel), Self.maxChannelIndexLimit - 1)
        ensureChannelCapacity(bus: .output, upToIndex: rawClamped)
        let targetIndex = canonicalOutputIndex(rawClamped)
        pendingColdStartAdjustments.removeValue(forKey: targetIndex)

        let limitDb = VolumeSafetyLimit.clampCeilingDb(safetyMaxDb)
        let limitNorm = RMEFaderCurve.dbToNormalized(limitDb)
        var clampedNorm = RMEFaderCurve.clampNormalized(normalized)
        var hitZeroDbLock = false
        if safetyClamp0dB && clampedNorm > limitNorm {
            clampedNorm = limitNorm
            hitZeroDbLock = true
        }

        return commitOptimisticOutputFader(
            targetIndex: targetIndex,
            normalized: clampedNorm,
            hitZeroDbLock: hitZeroDbLock,
            safetyMaxDb: safetyClamp0dB ? limitDb : nil,
            timestamp: nowProvider()
        )
    }

    /// 直接按分贝值 (`-65.0 ... +6.0 dB`) 设置指定硬件输出通道推子。
    @discardableResult
    public func setOutputFaderDb(
        channel: Int,
        db: Double,
        safetyClamp0dB: Bool = false,
        safetyMaxDb: Double = VolumeSafetyLimit.defaultMaxDb
    ) -> FaderStepResult {
        let limitDb = VolumeSafetyLimit.clampCeilingDb(safetyMaxDb)
        let hitLock = safetyClamp0dB && db > limitDb
        let effectiveDb = hitLock ? limitDb : db
        let norm = RMEFaderCurve.dbToNormalized(effectiveDb)
        var result = setOutputFaderNormalized(
            channel: channel,
            normalized: norm,
            safetyClamp0dB: false,
            safetyMaxDb: limitDb
        )
        if hitLock || safetyClamp0dB {
            result = FaderStepResult(
                channelIndex: result.channelIndex,
                displayName: result.displayName,
                normalizedFader: result.normalizedFader,
                dbValue: result.dbValue,
                formattedDb: result.formattedDb,
                hitZeroDbLock: hitLock,
                safetyMaxDb: safetyClamp0dB ? limitDb : nil,
                isDeferredColdStart: false,
                isMuted: result.isMuted
            )
        }
        return result
    }

    /// 设置子混音路由推子（`/mix/{in|pb}/{src}/{out}/faderlin`）。
    public func setSubmixFaderNormalized(
        sourceBus: MixerBus,
        sourceIndex: Int,
        outputIndex: Int,
        normalized: Double
    ) {
        guard let mixSegment = sourceBus.oscMixSourceSegment else { return }
        let targetSource = FirefaceUCXProfile.canonicalControlIndex(
            max(0, sourceIndex),
            in: sourceBus == .input ? inputChannels : playbackChannels
        )
        let targetOutput = canonicalOutputIndex(outputIndex)
        let norm = RMEFaderCurve.clampNormalized(normalized)
        let db = RMEFaderCurve.normalizedToDb(norm)
        let key = SubmixRouteKey(sourceBus: sourceBus, sourceIndex: targetSource, outputIndex: targetOutput)

        submixRoutes[key] = SubmixRouteState(
            key: key,
            normalizedFader: norm,
            dbValue: db,
            formattedDb: RMEFaderCurve.formatDb(db),
            hasConfirmedValue: true
        )
        sendOSC(.float("/mix/\(mixSegment)/\(targetSource)/\(targetOutput)/faderlin", norm))
    }

    // MARK: - Mute, Control Room, Snapshots, Layouts & Window

    /// 切换指定硬件输出通道的独立静音（发送 `/output/{2k}/mute` `1.0f` / `0.0f`）。
    @discardableResult
    public func toggleOutputMute(channel: Int) -> Bool {
        let targetIndex = canonicalOutputIndex(channel)
        ensureChannelCapacity(bus: .output, upToIndex: targetIndex)
        let desired = !outputChannels[targetIndex].isMuted
        setOutputMute(channel: targetIndex, muted: desired)
        return desired
    }

    /// 显式设置指定硬件输出通道静音状态。
    public func setOutputMute(channel: Int, muted: Bool) {
        let targetIndex = canonicalOutputIndex(channel)
        ensureChannelCapacity(bus: .output, upToIndex: targetIndex)
        outputChannels[targetIndex].isMuted = muted
        if outputChannels[targetIndex].isStereo, outputChannels.indices.contains(targetIndex + 1) {
            outputChannels[targetIndex + 1].isMuted = muted
        }
        sendOSC(.float("/output/\(targetIndex)/mute", muted ? Float(1.0) : Float(0.0)))
        scheduleOutputSettleSync(channel: targetIndex)
    }

    /// 切换任意总线（`input` / `playback` / `output`）指定通道的静音状态。
    @discardableResult
    public func toggleChannelMute(bus: MixerBus, channel: Int) -> Bool {
        switch bus {
        case .output:
            return toggleOutputMute(channel: channel)
        case .input:
            let idx = FirefaceUCXProfile.canonicalControlIndex(max(0, channel), in: inputChannels)
            ensureChannelCapacity(bus: .input, upToIndex: idx)
            let desired = !inputChannels[idx].isMuted
            inputChannels[idx].isMuted = desired
            if inputChannels[idx].isStereo, inputChannels.indices.contains(idx + 1) {
                inputChannels[idx + 1].isMuted = desired
            }
            sendOSC(.float("/input/\(idx)/mute", desired ? Float(1.0) : Float(0.0)))
            return desired
        case .playback:
            let idx = FirefaceUCXProfile.canonicalControlIndex(max(0, channel), in: playbackChannels)
            ensureChannelCapacity(bus: .playback, upToIndex: idx)
            let desired = !playbackChannels[idx].isMuted
            playbackChannels[idx].isMuted = desired
            if playbackChannels[idx].isStereo, playbackChannels.indices.contains(idx + 1) {
                playbackChannels[idx + 1].isMuted = desired
            }
            sendOSC(.float("/playback/\(idx)/mute", desired ? Float(1.0) : Float(0.0)))
            return desired
        }
    }

    /// 切换 Control Room 监听室功能或全局静音（`dim` / `mainmono` / `speakerb` / `talkback` / `globalmute` / `recall`）。
    @discardableResult
    public func toggleControlRoom(_ function: ControlRoomFunction) -> Bool {
        switch function {
        case .dim:
            let next = !controlRoom.dim
            setControlRoom(.dim, enabled: next)
            return next
        case .mono:
            let next = !controlRoom.mono
            setControlRoom(.mono, enabled: next)
            return next
        case .speakerB:
            let next = !controlRoom.speakerB
            setControlRoom(.speakerB, enabled: next)
            return next
        case .talkback:
            let next = !controlRoom.talkback
            setControlRoom(.talkback, enabled: next)
            return next
        case .globalMute:
            let next = !controlRoom.globalMute
            setControlRoom(.globalMute, enabled: next)
            return next
        case .mainRecall:
            sendOSC(.float(ControlRoomFunction.mainRecall.oscAddress, Float(1.0)))
            return true
        }
    }

    /// 显式设置 Control Room 监听室开关状态。
    public func setControlRoom(_ function: ControlRoomFunction, enabled: Bool) {
        switch function {
        case .dim:
            controlRoom.dim = enabled
        case .mono:
            controlRoom.mono = enabled
        case .speakerB:
            controlRoom.speakerB = enabled
        case .talkback:
            controlRoom.talkback = enabled
        case .globalMute:
            controlRoom.globalMute = enabled
        case .mainRecall:
            if enabled {
                sendOSC(.float(function.oscAddress, Float(1.0)))
            }
            return
        }
        sendOSC(.float(function.oscAddress, enabled ? Float(1.0) : Float(0.0)))
    }

    /// 加载 TotalMix 快照（`1...8`，`1-based`；越界参数安全忽略）。
    public func loadSnapshot(_ index: Int) {
        guard (1...8).contains(index) else { return }
        controlRoom.activeSnapshot = index
        sendOSC(.float("/snapshot/load/\(index)", Float(1.0)))
    }

    /// 保存当前状态至指定 TotalMix 快照（`1...8`，`1-based`）。
    public func saveSnapshot(_ index: Int) {
        guard (1...8).contains(index) else { return }
        sendOSC(.float("/snapshot/save/\(index)", Float(1.0)))
    }

    /// 加载 TotalMix 布局预设（`1...6`，`1-based`；注意上限为 `6` 而非 `8`）。
    public func loadLayout(_ index: Int) {
        guard (1...6).contains(index) else { return }
        sendOSC(.float("/layout/load/\(index)", Float(1.0)))
    }

    /// 切换 TotalMix FX 主窗口显示/隐藏（发送 `/showwindow` `1.0f` / `0.0f`）。
    @discardableResult
    public func toggleTotalMixWindow() -> Bool {
        let next = !isTotalMixWindowVisible
        setTotalMixWindowVisible(next)
        return next
    }

    /// 显式显示或隐藏 TotalMix FX 主窗口。
    public func setTotalMixWindowVisible(_ visible: Bool) {
        isTotalMixWindowVisible = visible
        sendOSC(.float("/showwindow", visible ? Float(1.0) : Float(0.0)))
    }

    // MARK: - Inbound OSC Processing

    /// 批量处理收到的 OSC 消息。
    public func handleIncomingMessages(_ messages: [OSCMessage], timestamp: TimeInterval? = nil) {
        let rxTime = timestamp ?? nowProvider()
        for message in messages {
            handleIncomingMessage(message, timestamp: rxTime)
        }
    }

    /// 处理单条收到的 Global OSC 消息。
    public func handleIncomingMessage(_ message: OSCMessage, timestamp: TimeInterval? = nil) {
        let rxTime = timestamp ?? nowProvider()
        let address = message.address
        guard address.hasPrefix("/"), address != "/" else { return }

        if isDiagnosticsCaptureEnabled {
            appendDiagnostic(
                direction: "RX",
                summary: "\(address) \(Self.formatArgsForLog(message.arguments))",
                timestamp: rxTime
            )
        }

        if processGlobalOSCMessage(message, timestamp: rxTime) {
            markValidResponseReceived(timestamp: rxTime)
        }
    }

    // MARK: - Private Message Router

    private func processGlobalOSCMessage(_ message: OSCMessage, timestamp: TimeInterval) -> Bool {
        let address = message.address
        let firstArg = message.arguments.first

        // 1. /status/*（如 /status/device, /status/version, /status/samplerate, /status/dsp, /status/connection）
        if address.hasPrefix("/status/") {
            let key = String(address.dropFirst("/status/".count))
            if key == "device", let devName = firstArg?.stringValue, !devName.isEmpty {
                if detectedDeviceName != devName {
                    detectedDeviceName = devName
                }
            } else if key == "dsp", let load = firstArg?.doubleValue {
                if dspLoad != load {
                    dspLoad = load
                }
            }
            return true
        }

        // 2. 全局静音与监听室 /globalmute, /globalsolo, /controlroom/*
        if address == "/globalmute" {
            if let flag = firstArg?.boolValue, controlRoom.globalMute != flag {
                controlRoom.globalMute = flag
            }
            return true
        }
        if address == "/globalsolo" {
            return true
        }
        if address.hasPrefix("/controlroom/") {
            let sub = String(address.dropFirst("/controlroom/".count))
            switch sub {
            case "dim":
                if let flag = firstArg?.boolValue, controlRoom.dim != flag { controlRoom.dim = flag }
            case "mainmono":
                if let flag = firstArg?.boolValue, controlRoom.mono != flag { controlRoom.mono = flag }
            case "speakerb":
                if let flag = firstArg?.boolValue, controlRoom.speakerB != flag { controlRoom.speakerB = flag }
            case "talkback":
                if let flag = firstArg?.boolValue, controlRoom.talkback != flag { controlRoom.talkback = flag }
            case "mainout":
                if let ch = firstArg?.intValue, ch >= 0, ch < Self.maxChannelIndexLimit {
                    if controlRoom.mainOutChannelIndex != ch {
                        controlRoom.mainOutChannelIndex = ch
                    }
                    hasReceivedMainOutFromOSC = true
                }
            default:
                break
            }
            return true
        }

        // 3. 快照状态 /snapshot/load/{1..8}
        if address.hasPrefix("/snapshot/load/") {
            let slotStr = address.dropFirst("/snapshot/load/".count)
            if let slot = Int(slotStr), (1...8).contains(slot), let val = firstArg?.doubleValue {
                // Global OSC 中 val >= 2.0 代表当前激活快照
                if val >= 1.5 {
                    if controlRoom.activeSnapshot != slot {
                        controlRoom.activeSnapshot = slot
                    }
                } else if controlRoom.activeSnapshot == slot {
                    controlRoom.activeSnapshot = nil
                }
                return true
            }
        }

        // 4. 编组 / 电平表 / 全局效果 / DURec（合法 Global OSC 报文，计入在线心跳）
        if address.hasPrefix("/mutegroup/")
            || address.hasPrefix("/sologroup/")
            || address.hasPrefix("/fadergroup/")
            || address.hasPrefix("/level/")
            || address.hasPrefix("/reverb/")
            || address.hasPrefix("/echo/")
            || address.hasPrefix("/durec/")
        {
            return true
        }

        // 5. 子混音 /mix/{in|pb}/{src}/{out}/{fader|faderlin|balpan|...}
        if address.hasPrefix("/mix/") {
            let parts = address.dropFirst("/mix/".count).split(separator: "/", omittingEmptySubsequences: false)
            if parts.count >= 4,
               let srcIdx = Int(parts[1]),
               let outIdx = Int(parts[2]),
               srcIdx >= 0, srcIdx < Self.maxChannelIndexLimit,
               outIdx >= 0, outIdx < Self.maxChannelIndexLimit
            {
                let bus: MixerBus? = switch parts[0] {
                case "in": .input
                case "pb": .playback
                default: nil
                }
                if let bus {
                    let param = parts[3]
                    let key = SubmixRouteKey(sourceBus: bus, sourceIndex: srcIdx, outputIndex: outIdx)
                    if param == "fader", let db = firstArg?.doubleValue {
                        let norm = RMEFaderCurve.dbToNormalized(db)
                        let clampedDb = db <= RMEFaderCurve.minDb ? RMEFaderCurve.minDb : min(RMEFaderCurve.maxDb, db)
                        let newRoute = SubmixRouteState(
                            key: key,
                            normalizedFader: norm,
                            dbValue: clampedDb,
                            formattedDb: RMEFaderCurve.formatDb(db),
                            hasConfirmedValue: true
                        )
                        if submixRoutes[key] != newRoute {
                            submixRoutes[key] = newRoute
                        }
                    } else if param == "faderlin", let rawNorm = firstArg?.doubleValue {
                        let norm = RMEFaderCurve.clampNormalized(rawNorm)
                        let db = RMEFaderCurve.normalizedToDb(norm)
                        let newRoute = SubmixRouteState(
                            key: key,
                            normalizedFader: norm,
                            dbValue: db,
                            formattedDb: RMEFaderCurve.formatDb(db),
                            hasConfirmedValue: true
                        )
                        if submixRoutes[key] != newRoute {
                            submixRoutes[key] = newRoute
                        }
                    }
                    return true
                }
            }
        }

        // 6. 通道消息 /{input|playback|output}/{ch}/{param...}
        let segments = address.dropFirst().split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
        if segments.count == 3,
           let bus = MixerBus(rawValue: String(segments[0])),
           let channelIndex = Int(segments[1]),
           channelIndex >= 0,
           channelIndex < Self.maxChannelIndexLimit
        {
            let parameterPath = String(segments[2])
            handleChannelMessage(
                bus: bus,
                index: channelIndex,
                parameterPath: parameterPath,
                argument: firstArg,
                timestamp: timestamp
            )
            return true
        }

        return false
    }

    private func handleChannelMessage(
        bus: MixerBus,
        index: Int,
        parameterPath: String,
        argument: OSCArgument?,
        timestamp: TimeInterval
    ) {
        ensureChannelCapacity(bus: bus, upToIndex: index)

        switch parameterPath {
        case "name":
            guard let rawName = argument?.stringValue else { return }
            mutateChannel(bus: bus, index: index) { ch in
                ch.rawName = rawName
                ch.displayName = FirefaceUCXProfile.resolveDisplayName(
                    bus: bus,
                    index: index,
                    rawName: rawName,
                    isStereo: ch.isStereo
                )
            }

        case "stereo":
            guard let stereo = argument?.boolValue else { return }
            if index % 2 == 0 {
                ensureChannelCapacity(bus: bus, upToIndex: index + 1)
                mutateChannel(bus: bus, index: index) { ch in
                    ch.isStereo = stereo
                    ch.displayName = FirefaceUCXProfile.resolveDisplayName(
                        bus: bus,
                        index: index,
                        rawName: ch.rawName,
                        isStereo: stereo
                    )
                }
                mutateChannel(bus: bus, index: index + 1) { partner in
                    partner.isHiddenPartner = stereo
                    partner.displayName = FirefaceUCXProfile.resolveDisplayName(
                        bus: bus,
                        index: index + 1,
                        rawName: partner.rawName,
                        isStereo: false
                    )
                }
            }

        case "color":
            guard let color = argument?.intValue else { return }
            mutateChannel(bus: bus, index: index) { ch in
                ch.color = color
            }

        case "mute":
            guard let muted = argument?.boolValue else { return }
            mutateChannel(bus: bus, index: index) { ch in
                ch.isMuted = muted
            }
            if index % 2 == 0 {
                let isPair = channelState(bus: bus, index: index).isStereo
                if isPair {
                    ensureChannelCapacity(bus: bus, upToIndex: index + 1)
                    mutateChannel(bus: bus, index: index + 1) { partner in
                        partner.isMuted = muted
                    }
                }
            }

        case "volume":
            // 默认配置下 TotalMix 回传 /output/{ch}/volume <dB>（含 -300.0 dB）
            guard bus == .output, let rawDb = argument?.doubleValue else { return }
            let norm = RMEFaderCurve.dbToNormalized(rawDb)
            let clampedDb = rawDb <= RMEFaderCurve.minDb
                ? RMEFaderCurve.minDb
                : min(RMEFaderCurve.maxDb, rawDb)
            let formatted = RMEFaderCurve.formatDb(rawDb)
            applyConfirmedOutputFader(
                index: index,
                normalized: norm,
                dbValue: clampedDb,
                formattedDb: formatted,
                timestamp: timestamp
            )

        case "faderlin":
            // 若用户在 Details 勾选 Send faders in linear scale，回传 /output/{ch}/faderlin <0..1>
            guard bus == .output, let rawNorm = argument?.doubleValue else { return }
            let norm = RMEFaderCurve.clampNormalized(rawNorm)
            let db = RMEFaderCurve.normalizedToDb(norm)
            let formatted = RMEFaderCurve.formatDb(db)
            applyConfirmedOutputFader(
                index: index,
                normalized: norm,
                dbValue: db,
                formattedDb: formatted,
                timestamp: timestamp
            )

        case "fader":
            // 兼容部分固件对通道推子回传 /{bus}/{ch}/fader <dB>
            guard let rawDb = argument?.doubleValue else { return }
            let norm = RMEFaderCurve.dbToNormalized(rawDb)
            let clampedDb = rawDb <= RMEFaderCurve.minDb
                ? RMEFaderCurve.minDb
                : min(RMEFaderCurve.maxDb, rawDb)
            let formatted = RMEFaderCurve.formatDb(rawDb)
            if bus == .output {
                applyConfirmedOutputFader(
                    index: index,
                    normalized: norm,
                    dbValue: clampedDb,
                    formattedDb: formatted,
                    timestamp: timestamp
                )
            } else {
                mutateChannel(bus: bus, index: index) { ch in
                    ch.normalizedFader = norm
                    ch.dbValue = clampedDb
                    ch.formattedDb = formatted
                    ch.hasConfirmedValue = true
                }
            }

        default:
            break
        }
    }

    // MARK: - Output Fader State Reconciliation

    private func commitOptimisticOutputFader(
        targetIndex: Int,
        normalized: Double,
        hitZeroDbLock: Bool,
        safetyMaxDb: Double? = nil,
        timestamp: TimeInterval
    ) -> FaderStepResult {
        let clampedNorm = RMEFaderCurve.clampNormalized(normalized)
        let db = RMEFaderCurve.normalizedToDb(clampedNorm)
        let formatted = RMEFaderCurve.formatDb(db)

        outputChannels[targetIndex].normalizedFader = clampedNorm
        outputChannels[targetIndex].dbValue = db
        outputChannels[targetIndex].formattedDb = formatted
        outputChannels[targetIndex].hasConfirmedValue = true

        if outputChannels[targetIndex].isStereo, outputChannels.indices.contains(targetIndex + 1) {
            outputChannels[targetIndex + 1].normalizedFader = clampedNorm
            outputChannels[targetIndex + 1].dbValue = db
            outputChannels[targetIndex + 1].formattedDb = formatted
        }

        // 开启 220ms 乐观防抖窗口（到期后绝不回滚状态）
        optimisticOutputs[targetIndex] = OptimisticFaderGuard(
            normalizedValue: clampedNorm,
            expiresAt: timestamp + optimisticWindowSeconds
        )

        // 仅向偶数左通道（或单声道自身）发送 faderlin Float32
        sendOSC(.float("/output/\(targetIndex)/faderlin", clampedNorm))

        // 重置 250ms 停手定音同步防抖计时器
        scheduleOutputSettleSync(channel: targetIndex)

        let updated = outputChannels[targetIndex]
        return FaderStepResult(
            channelIndex: targetIndex,
            displayName: updated.displayName,
            normalizedFader: updated.normalizedFader,
            dbValue: updated.dbValue,
            formattedDb: updated.formattedDb,
            hitZeroDbLock: hitZeroDbLock,
            safetyMaxDb: safetyMaxDb,
            isDeferredColdStart: false,
            isMuted: updated.isMuted
        )
    }

    private func applyConfirmedOutputFader(
        index: Int,
        normalized: Double,
        dbValue: Double,
        formattedDb: String,
        timestamp: TimeInterval
    ) {
        // 若处于 220ms 乐观窗口内，抑制与最新目标值不一致的滞后旧回包，防止快速拧动时推子回弹
        if let activeGuard = optimisticOutputs[index] {
            if timestamp < activeGuard.expiresAt {
                if abs(normalized - activeGuard.normalizedValue) > 0.0025 {
                    return
                }
                optimisticOutputs.removeValue(forKey: index)
            } else {
                // 窗口已自然到期，不回滚，直接清理并接受最新权威值
                optimisticOutputs.removeValue(forKey: index)
            }
        }

        mutateChannel(bus: .output, index: index) { ch in
            ch.normalizedFader = normalized
            ch.dbValue = dbValue
            ch.formattedDb = formattedDb
            ch.hasConfirmedValue = true
        }

        // 冷启动防跳变落地：一旦拿到真实初始音量，立即将暂存增量平滑叠加发送并通知补弹 HUD！
        if let pending = pendingColdStartAdjustments.removeValue(forKey: index) {
            let applied = adjustOutputFaderDb(
                channel: index,
                deltaDb: pending.deltaDb,
                safetyClamp0dB: pending.safetyClamp0dB,
                safetyMaxDb: pending.safetyMaxDb
            )
            if !applied.isDeferredColdStart {
                onDeferredOutputFaderApplied?(applied)
            }
        }
    }

    private func scheduleOutputSettleSync(channel: Int) {
        settleSyncTasks[channel]?.cancel()
        let delaySeconds = settleSyncDebounceSeconds
        guard delaySeconds > 0 else {
            optimisticOutputs.removeValue(forKey: channel)
            sendOSC(.float("/sendchan/output/\(channel)", Float(1.0)))
            return
        }

        settleSyncTasks[channel] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delaySeconds))
            guard !Task.isCancelled, let self else { return }
            self.settleSyncTasks.removeValue(forKey: channel)
            self.optimisticOutputs.removeValue(forKey: channel)
            self.sendOSC(.float("/sendchan/output/\(channel)", Float(1.0)))
        }
    }

    // MARK: - Connection & Transport Plumbing

    private func markValidResponseReceived(timestamp: TimeInterval) {
        lastMessageTimestamp = timestamp
        if offlineDiagnostic != nil {
            offlineDiagnostic = nil
        }
        let wasConnected = isConnected
        if !wasConnected {
            isConnected = true
        }

        if !wasConnected || !hasInitialSyncCompleted {
            hasInitialSyncCompleted = true
            requestFullSync()
        }
    }

    private func handleTransportEvent(_ event: OSCInboundEvent) {
        switch event {
        case .transportStateChanged(let state):
            if transportState != state {
                transportState = state
            }
            if case .portInUse = state {
                if isConnected { isConnected = false }
            } else if case .failed = state {
                if isConnected { isConnected = false }
            }
        case .messagesReceived(let messages, _, let timestamp):
            handleIncomingMessages(messages, timestamp: timestamp)
        case .diagnostic(let direction, let summary, let timestamp):
            if isDiagnosticsCaptureEnabled || direction == "TX-ERR" {
                appendDiagnostic(direction: direction, summary: summary, timestamp: timestamp)
            }
        }
    }

    private func scheduleOfflineProbeCheck() {
        offlineProbeTask?.cancel()
        let timeout = max(0.05, offlineProbeTimeoutSeconds)
        offlineProbeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self else { return }
            if !self.isConnected {
                self.refreshOfflineDiagnostic()
            }
        }
    }

    private func stopBackgroundTasks() {
        inboundConsumerTask?.cancel()
        inboundConsumerTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        offlineProbeTask?.cancel()
        offlineProbeTask = nil
    }

    private func sendOSC(_ message: OSCMessage) {
        if let customSendHandler {
            if isDiagnosticsCaptureEnabled {
                appendDiagnostic(
                    direction: "TX",
                    summary: "\(message.address) \(Self.formatArgsForLog(message.arguments))",
                    timestamp: nowProvider()
                )
            }
            customSendHandler(message)
        } else {
            transport?.send(message, includeDiagnostic: isDiagnosticsCaptureEnabled)
        }
    }

    private func appendDiagnostic(direction: String, summary: String, timestamp: TimeInterval) {
        recentDiagnostics.append(
            OSCDiagnosticEntry(direction: direction, summary: summary, timestamp: timestamp)
        )
        if recentDiagnostics.count > Self.maxDiagnosticEntries {
            recentDiagnostics.removeFirst(recentDiagnostics.count - Self.maxDiagnosticEntries)
        }
    }

    // MARK: - Dynamic Channel Storage Helpers

    private func ensureChannelCapacity(bus: MixerBus, upToIndex index: Int) {
        guard index >= 0, index < Self.maxChannelIndexLimit else { return }
        switch bus {
        case .input:
            appendMissingChannels(to: &inputChannels, bus: .input, upToIndex: index)
        case .playback:
            appendMissingChannels(to: &playbackChannels, bus: .playback, upToIndex: index)
        case .output:
            appendMissingChannels(to: &outputChannels, bus: .output, upToIndex: index)
        }
    }

    private func appendMissingChannels(
        to array: inout [MixerChannelState],
        bus: MixerBus,
        upToIndex index: Int
    ) {
        guard index >= array.count else { return }
        for newIdx in array.count...index {
            let monoName = FirefaceUCXProfile.monoDefaultLabel(bus: bus, index: newIdx)
            array.append(
                MixerChannelState(
                    index: newIdx,
                    bus: bus,
                    rawName: "",
                    displayName: monoName,
                    isStereo: false,
                    isHiddenPartner: false,
                    color: 1,
                    normalizedFader: 0.0,
                    dbValue: RMEFaderCurve.minDb,
                    formattedDb: "-∞ dB",
                    isMuted: false,
                    hasConfirmedValue: false
                )
            )
        }
    }

    private func channelState(bus: MixerBus, index: Int) -> MixerChannelState {
        switch bus {
        case .input: return inputChannels[index]
        case .playback: return playbackChannels[index]
        case .output: return outputChannels[index]
        }
    }

    private func mutateChannel(
        bus: MixerBus,
        index: Int,
        _ body: (inout MixerChannelState) -> Void
    ) {
        switch bus {
        case .input:
            guard inputChannels.indices.contains(index) else { return }
            let existing = inputChannels[index]
            var updated = existing
            body(&updated)
            if updated != existing {
                inputChannels[index] = updated
            }
        case .playback:
            guard playbackChannels.indices.contains(index) else { return }
            let existing = playbackChannels[index]
            var updated = existing
            body(&updated)
            if updated != existing {
                playbackChannels[index] = updated
            }
        case .output:
            guard outputChannels.indices.contains(index) else { return }
            let existing = outputChannels[index]
            var updated = existing
            body(&updated)
            if updated != existing {
                outputChannels[index] = updated
            }
        }
    }

    private static func formatArgsForLog(_ args: [OSCArgument]) -> String {
        args.map { arg in
            switch arg {
            case .float32(let f):
                return String(format: "%.3ff", f)
            case .int32(let i):
                return "\(i)i"
            case .string(let s):
                return "\"\(s)\""
            case .bool(let b):
                return b ? "T" : "F"
            }
        }.joined(separator: " ")
    }
}
