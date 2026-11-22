import AppKit
import Foundation
import Observation

/// 供 App 层无焦点毛玻璃 HUD 消费的纯值事件模型（与 `HUDPayload` 字段一一对齐）。
public struct CoordinatorHUDEvent: Equatable, Sendable {
    public let title: String
    public let subtitle: String?
    public let dbText: String
    public let normalizedLevel: Double
    public let unityNormalizedPosition: Double
    public let safetyLimitNormalizedPosition: Double?
    public let isMuted: Bool
    public let hitZeroDbLock: Bool
    public let badgeText: String?
    public let systemIcon: String

    public init(
        title: String,
        subtitle: String? = nil,
        dbText: String,
        normalizedLevel: Double,
        unityNormalizedPosition: Double = RMEFaderCurve.zeroDbNormalized,
        safetyLimitNormalizedPosition: Double? = nil,
        isMuted: Bool = false,
        hitZeroDbLock: Bool = false,
        badgeText: String? = nil,
        systemIcon: String = "hifispeaker.2.fill"
    ) {
        self.title = title
        self.subtitle = subtitle
        self.dbText = dbText
        self.normalizedLevel = normalizedLevel
        self.unityNormalizedPosition = unityNormalizedPosition
        self.safetyLimitNormalizedPosition = safetyLimitNormalizedPosition
        self.isMuted = isMuted
        self.hitZeroDbLock = hitZeroDbLock
        self.badgeText = badgeText
        self.systemIcon = systemIcon
    }
}

/// 串口诊断监视器日志条目。
public struct SerialDiagnosticEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let direction: String
    public let hex: String
    public let note: String
    public let timestamp: TimeInterval

    public init(
        id: UUID = UUID(),
        direction: String,
        hex: String,
        note: String,
        timestamp: TimeInterval
    ) {
        self.id = id
        self.direction = direction
        self.hex = hex
        self.note = note
        self.timestamp = timestamp
    }
}

/// TourMix 核心总控调度引擎（`@MainActor @Observable`）。
///
/// 职责：
/// - 汇总消费 `TourBoxSerialService` 与 `TotalMixController` 状态；
/// - 驱动 `ControlStateMachine`（修饰键 On-Release Tap、双击窗口定时器、乱序释放保护）与按槽位隔离的 `RotaryBallisticsState`；
/// - 维护供矢量机身画布实时呼吸高亮的 `activePhysicalControls`（旋钮 `.rotaryStep` 触发 `150 ms` 可取消防抖熄灭，严格忽略 `0xC4/0x84` 停止码）；
/// - 管理多预设切换、前台应用自动切预设与 `config.json` 原子热保存。
@MainActor
@Observable
public final class CoordinatorEngine {
    // MARK: - Public Subsystems & Observable State

    public let totalMix: TotalMixController
    public let serialService: TourBoxSerialService?
    public let actionExecutor: SystemActionExecutor

    public private(set) var configuration: AppConfiguration
    public private(set) var tourBoxState: TourBoxConnectionState = .disconnected
    public private(set) var serialDiagnostics: [SerialDiagnosticEntry] = []

    /// 是否按需采集串口输入与 OSC 报文诊断日志（仅诊断面板打开时开启，平时仅保留少量系统级握手日志）。
    @ObservationIgnored
    public private(set) var isDiagnosticsCaptureEnabled: Bool = false

    /// 当前物理按下或正在旋转高亮（150ms 防抖）的控件区域集合（供 `TourBoxLiteCanvas` 实时发光）。
    public private(set) var activePhysicalControls: Set<TourBoxControlId> = []

    /// 当前正被按住的硬件修饰键栈。
    public private(set) var activeHardwareModifiers: [TourBoxButton] = []

    /// 最近一次配置保存错误（若有）。
    public private(set) var lastPersistenceError: String?

    /// HUD 浮层通知回调（由 `TourMixApp` 注入连接到 `HUDPanelController`）。
    public var onHUDEvent: ((CoordinatorHUDEvent) -> Void)?

    /// 硬件按键触发「打开按键映射工作台」回调。
    public var onOpenKeymapperRequested: (() -> Void)?

    // MARK: - Computed Properties

    /// 当前激活的预设。
    public var activeProfile: ProfileConfig {
        if let match = configuration.profiles.first(where: { $0.id == configuration.activeProfileId }) {
            return match
        }
        return configuration.profiles.first ?? .factoryDefault
    }

    /// 当前预设已绑定的去重输出通道列表（供菜单栏面板自适应渲染 `1..N` 张通道卡片）。
    public var boundOutputChannels: [(channelIndex: Int, safetyClamp0dB: Bool, safetyMaxDb: Double)] {
        activeProfile.boundOutputChannels.map { item in
            (
                channelIndex: totalMix.canonicalOutputIndex(item.channelIndex),
                safetyClamp0dB: item.safetyClamp0dB,
                safetyMaxDb: item.safetyMaxDb
            )
        }.reduce(into: []) { acc, entry in
            if !acc.contains(where: { $0.channelIndex == entry.channelIndex }) {
                acc.append(entry)
            }
        }
    }

    /// 供状态栏图标旁可选显示的等宽主控通道分贝文本（若启用 `showDbInMenuBar`）。
    public var menuBarStatusDbText: String? {
        guard configuration.showDbInMenuBar,
              let primary = boundOutputChannels.first,
              let ch = totalMix.outputChannel(at: primary.channelIndex)
        else {
            return nil
        }
        if ch.isMuted {
            return "MUTE"
        }
        return ch.hasConfirmedValue ? ch.formattedDb : "-- dB"
    }

    /// 当前激活修饰键（取栈顶），用于画布实时预览组合层标签。
    public var currentActiveModifier: TourBoxButton? {
        activeHardwareModifiers.last
    }

    /// 供 `TourBoxLiteCanvas` 直接绑定的 8 控件标签摘要表。
    public var activeBindingSummaries: [TourBoxControlId: (primary: String?, secondary: String?)] {
        activeProfile.allBindingSummaries(activeModifier: currentActiveModifier) { [weak self] bus, idx in
            self?.channelDisplayName(bus: bus, index: idx)
                ?? FirefaceUCXProfile.stereoDefaultLabel(bus: bus, evenIndex: idx)
        }
    }

    // MARK: - Private State

    private static let maxSerialDiagnostics = 120
    private static let maxBackgroundSystemDiagnostics = 30
    private static let rotaryGlowDurationMs = 150

    private let configFileURL: URL?
    private let persistChangesToDisk: Bool
    private var stateMachine = ControlStateMachine()
    private var ballisticsBySlot: [String: RotaryBallisticsState] = [:]
    private var physicallyHeldButtons: Set<TourBoxButton> = []

    private var serialConsumerTask: Task<Void, Never>?
    private var doubleClickTimerTask: Task<Void, Never>?
    private var rotaryGlowTasks: [TourBoxRotary: Task<Void, Never>] = [:]
    private var workspaceActivateObserver: NSObjectProtocol?
    private var workspaceSleepObserver: NSObjectProtocol?

    // MARK: - Initializers

    /// 生产环境构造器：自动加载 `~/Library/Application Support/TourMix/config.json`，初始化串口与 OSC 服务。
    public init(configFileURL: URL? = nil) {
        let loaded = AppConfiguration.load(from: configFileURL)
        self.configuration = loaded
        self.configFileURL = configFileURL
        self.persistChangesToDisk = true
        self.totalMix = TotalMixController(
            host: loaded.oscHost,
            outgoingPort: loaded.oscOutgoingPort,
            incomingPort: loaded.oscIncomingPort
        )
        self.serialService = TourBoxSerialService()
        self.actionExecutor = SystemActionExecutor()
        wireTotalMixCallbacks()
        rebuildStateMachineConfiguration()
    }

    /// 单元测试与预览依赖注入构造器：支持注入自定义 `TotalMixController`、可选串口服务与内存态配置。
    public init(
        configuration: AppConfiguration = .factoryDefault,
        configFileURL: URL? = nil,
        persistChangesToDisk: Bool = false,
        totalMix: TotalMixController,
        serialService: TourBoxSerialService? = nil,
        actionExecutor: SystemActionExecutor? = nil
    ) {
        self.configuration = configuration
        self.configFileURL = configFileURL
        self.persistChangesToDisk = persistChangesToDisk
        self.totalMix = totalMix
        self.serialService = serialService
        self.actionExecutor = actionExecutor ?? SystemActionExecutor()
        wireTotalMixCallbacks()
        rebuildStateMachineConfiguration()
    }

    private func wireTotalMixCallbacks() {
        totalMix.onDeferredOutputFaderApplied = { [weak self] stepResult in
            self?.emitOutputFaderHUD(for: stepResult)
        }
    }

    deinit {
        serialService?.stop()
    }

    // MARK: - Lifecycle

    /// 启动串口热插拔监听、TotalMix OSC 引擎与前台应用切换监听。
    public func start() {
        stopConsumersAndObservers()

        totalMix.start()

        if let serialService {
            serialService.start()
            let stream = serialService.events
            serialConsumerTask = Task { [weak self] in
                for await event in stream {
                    guard !Task.isCancelled, let self else { break }
                    self.handleSerialEvent(event)
                }
            }
        }

        let wsCenter = NSWorkspace.shared.notificationCenter
        workspaceActivateObserver = wsCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .bundleIdentifier
            MainActor.assumeIsolated {
                self?.handleFrontmostAppActivated(bundleIdentifier: bundleID)
            }
        }

        workspaceSleepObserver = wsCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.releaseAllTransientControlStates()
            }
        }
    }

    /// 停止所有监听、释放合成修饰键并关闭底层服务。
    public func stop() {
        stopConsumersAndObservers()
        releaseAllTransientControlStates()
        serialService?.stop()
        totalMix.stop()
    }

    /// 手动触发 TourBox 串口重连。
    public func reconnectTourBoxNow() {
        releaseAllTransientControlStates()
        serialService?.reconnectNow()
    }

    /// 开关串口输入与 OSC 报文实时诊断日志采集；关闭时清理高频 `"IN"` 输入记录，仅保留最近系统握手/异常日志。
    public func setDiagnosticsCaptureEnabled(_ enabled: Bool) {
        isDiagnosticsCaptureEnabled = enabled
        totalMix.setDiagnosticsCaptureEnabled(enabled)
        if !enabled {
            let systemEntries = Array(
                serialDiagnostics
                    .filter { $0.direction != "IN" }
                    .suffix(20)
            )
            if serialDiagnostics != systemEntries {
                serialDiagnostics = systemEntries
            }
        }
    }

    // MARK: - Channel Display Helper

    /// 获取指定总线与通道索引的实时可读名称。
    public func channelDisplayName(bus: MixerBus, index: Int) -> String {
        switch bus {
        case .output:
            if let ch = totalMix.outputChannel(at: index) {
                return ch.displayName
            }
            return FirefaceUCXProfile.stereoDefaultLabel(bus: .output, evenIndex: index)
        case .input:
            let idx = FirefaceUCXProfile.canonicalControlIndex(max(0, index), in: totalMix.inputChannels)
            if totalMix.inputChannels.indices.contains(idx) {
                return totalMix.inputChannels[idx].displayName
            }
            return FirefaceUCXProfile.stereoDefaultLabel(bus: .input, evenIndex: idx)
        case .playback:
            let idx = FirefaceUCXProfile.canonicalControlIndex(max(0, index), in: totalMix.playbackChannels)
            if totalMix.playbackChannels.indices.contains(idx) {
                return totalMix.playbackChannels[idx].displayName
            }
            return FirefaceUCXProfile.stereoDefaultLabel(bus: .playback, evenIndex: idx)
        }
    }

    // MARK: - Serial Stream & Input Dispatch

    /// 处理单条串口事件（亦可供单元测试直接注入模拟事件）。
    public func handleSerialEvent(_ event: TourBoxSerialEvent) {
        switch event {
        case .stateChanged(let state):
            if tourBoxState != state {
                tourBoxState = state
            }
            if !state.isConnected {
                releaseAllTransientControlStates()
            }

        case .rawDiagnostic(let direction, let hex, let note):
            let now = ProcessInfo.processInfo.systemUptime
            appendSerialDiagnostic(direction: direction, hex: hex, note: note, timestamp: now)

        case .input(let decoded, let rawByte, let timestamp):
            if isDiagnosticsCaptureEnabled {
                appendSerialDiagnostic(
                    direction: "IN",
                    hex: String(format: "%02X", rawByte),
                    note: decoded.diagnosticSummary,
                    timestamp: timestamp
                )
            }
            handleDecodedInput(decoded, timestamp: timestamp)
        }
    }

    /// 直接注入单个已解码硬件字节与时间戳（便于确定性单元测试测速与防抖）。
    public func handleDecodedInput(_ decoded: TourBoxDecodedByte, timestamp: TimeInterval) {
        updatePhysicalHighlight(for: decoded)

        let triggers = stateMachine.process(decoded, timestamp: timestamp)
        if activeHardwareModifiers != stateMachine.activeModifiers {
            activeHardwareModifiers = stateMachine.activeModifiers
        }
        scheduleDoubleClickDeadlineIfNeeded(referenceNow: timestamp)

        for trigger in triggers {
            executeResolvedTrigger(trigger)
        }
    }

    // MARK: - MenuBar Direct Channel Controls

    /// 菜单栏面板水平推子直调指定硬件输出通道音量。
    public func setOutputChannelFaderNormalized(channelIndex: Int, normalized: Double) {
        let canonical = totalMix.canonicalOutputIndex(channelIndex)
        let channelConfig = boundOutputChannels.first(where: { $0.channelIndex == canonical })
        let clamp = channelConfig?.safetyClamp0dB ?? false
        let maxDb = channelConfig?.safetyMaxDb ?? VolumeSafetyLimit.defaultMaxDb
        _ = totalMix.setOutputFaderNormalized(
            channel: channelIndex,
            normalized: normalized,
            safetyClamp0dB: clamp,
            safetyMaxDb: maxDb
        )
    }

    /// 菜单栏面板切换指定硬件输出通道静音。
    @discardableResult
    public func toggleOutputChannelMute(channelIndex: Int) -> Bool {
        let muted = totalMix.toggleOutputMute(channel: channelIndex)
        if let ch = totalMix.outputChannel(at: channelIndex) {
            let canonical = totalMix.canonicalOutputIndex(channelIndex)
            let channelConfig = boundOutputChannels.first(where: { $0.channelIndex == canonical })
            let limitNorm: Double? = (channelConfig?.safetyClamp0dB == true)
                ? RMEFaderCurve.dbToNormalized(VolumeSafetyLimit.clampCeilingDb(channelConfig?.safetyMaxDb ?? 0.0))
                : nil
            emitHUDIfEnabled(
                CoordinatorHUDEvent(
                    title: ch.displayName,
                    subtitle: "Hardware Output",
                    dbText: muted ? "MUTED" : ch.formattedDb,
                    normalizedLevel: ch.normalizedFader,
                    unityNormalizedPosition: RMEFaderCurve.zeroDbNormalized,
                    safetyLimitNormalizedPosition: limitNorm,
                    isMuted: muted,
                    hitZeroDbLock: false,
                    badgeText: muted ? "MUTE" : nil,
                    systemIcon: muted ? "speaker.slash.fill" : "hifispeaker.2.fill"
                )
            )
        }
        return muted
    }

    /// 菜单栏卡片一键切换某输出通道在当前预设中的音量保护开关（保留原自定义上限）。
    public func setOutputChannelSafetyClamp(channelIndex: Int, enabled: Bool) {
        let targetCanonical = totalMix.canonicalOutputIndex(channelIndex)
        mutateActiveProfile { profile in
            for rotary in TourBoxRotary.allCases {
                if case .rmeOutputFader(let ch, let ballistics, _, let maxDb) = profile.rotaryBindings[rotary],
                   totalMix.canonicalOutputIndex(ch) == targetCanonical
                {
                    profile.rotaryBindings[rotary] = .rmeOutputFader(
                        channelIndex: targetCanonical,
                        ballistics: ballistics,
                        safetyClamp0dB: enabled,
                        safetyMaxDb: maxDb
                    )
                }
            }
            for (comboKey, action) in profile.rotaryComboBindings {
                if case .rmeOutputFader(let ch, let ballistics, _, let maxDb) = action,
                   totalMix.canonicalOutputIndex(ch) == targetCanonical
                {
                    profile.rotaryComboBindings[comboKey] = .rmeOutputFader(
                        channelIndex: targetCanonical,
                        ballistics: ballistics,
                        safetyClamp0dB: enabled,
                        safetyMaxDb: maxDb
                    )
                }
            }
        }
    }

    /// 更新指定输出通道在当前预设中的音量保护开关与自定义上限 dB。
    public func setOutputChannelSafetyLimit(channelIndex: Int, enabled: Bool, maxDb: Double) {
        let targetCanonical = totalMix.canonicalOutputIndex(channelIndex)
        let clampedLimit = VolumeSafetyLimit.clampCeilingDb(maxDb)
        mutateActiveProfile { profile in
            for rotary in TourBoxRotary.allCases {
                if case .rmeOutputFader(let ch, let ballistics, _, _) = profile.rotaryBindings[rotary],
                   totalMix.canonicalOutputIndex(ch) == targetCanonical
                {
                    profile.rotaryBindings[rotary] = .rmeOutputFader(
                        channelIndex: targetCanonical,
                        ballistics: ballistics,
                        safetyClamp0dB: enabled,
                        safetyMaxDb: clampedLimit
                    )
                }
            }
            for (comboKey, action) in profile.rotaryComboBindings {
                if case .rmeOutputFader(let ch, let ballistics, _, _) = action,
                   totalMix.canonicalOutputIndex(ch) == targetCanonical
                {
                    profile.rotaryComboBindings[comboKey] = .rmeOutputFader(
                        channelIndex: targetCanonical,
                        ballistics: ballistics,
                        safetyClamp0dB: enabled,
                        safetyMaxDb: clampedLimit
                    )
                }
            }
        }
    }

    // MARK: - Profile & Binding Mutation API

    public func selectProfile(id: UUID) {
        guard configuration.profiles.contains(where: { $0.id == id }),
              configuration.activeProfileId != id
        else {
            return
        }
        releaseAllTransientControlStates()
        configuration.activeProfileId = id
        rebuildStateMachineConfiguration()
        persistConfigurationIfNeeded()
    }

    public func cycleToNextProfile() {
        guard configuration.profiles.count > 1 else { return }
        let currentIdx = configuration.profiles.firstIndex(where: { $0.id == configuration.activeProfileId }) ?? 0
        let nextProfile = configuration.profiles[(currentIdx + 1) % configuration.profiles.count]
        selectProfile(id: nextProfile.id)
        emitHUDIfEnabled(
            CoordinatorHUDEvent(
                title: nextProfile.name,
                subtitle: "已切换预设",
                dbText: "PROFILE",
                normalizedLevel: 1.0,
                isMuted: false,
                hitZeroDbLock: false,
                badgeText: nil,
                systemIcon: "slider.horizontal.3"
            )
        )
    }

    @discardableResult
    public func createProfile(name: String, copyFromActive: Bool = false) -> ProfileConfig {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "新建预设 \(configuration.profiles.count + 1)" : trimmed
        var created: ProfileConfig
        if copyFromActive {
            created = activeProfile
            created.id = UUID()
            created.name = finalName
            created.associatedBundleIdentifier = nil
        } else {
            created = ProfileConfig.factoryDefault
            created.id = UUID()
            created.name = finalName
        }
        releaseAllTransientControlStates()
        configuration.profiles.append(created)
        configuration.activeProfileId = created.id
        rebuildStateMachineConfiguration()
        persistConfigurationIfNeeded()
        return created
    }

    public func renameProfile(id: UUID, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = configuration.profiles.firstIndex(where: { $0.id == id })
        else {
            return
        }
        configuration.profiles[idx].name = trimmed
        persistConfigurationIfNeeded()
    }

    public func setProfileBundleIdentifier(id: UUID, bundleIdentifier: String?) {
        guard let idx = configuration.profiles.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.profiles[idx].associatedBundleIdentifier = (trimmed?.isEmpty == true) ? nil : trimmed
        persistConfigurationIfNeeded()
    }

    public func deleteProfile(id: UUID) {
        guard configuration.profiles.count > 1,
              let idx = configuration.profiles.firstIndex(where: { $0.id == id })
        else {
            return
        }
        let wasActive = (configuration.activeProfileId == id)
        configuration.profiles.remove(at: idx)
        if wasActive {
            releaseAllTransientControlStates()
            configuration.activeProfileId = configuration.profiles[0].id
            rebuildStateMachineConfiguration()
        }
        persistConfigurationIfNeeded()
    }

    public func resetActiveProfileToFactoryDefault() {
        let currentID = activeProfile.id
        let currentName = activeProfile.name
        releaseAllTransientControlStates()
        mutateActiveProfile { profile in
            var fresh = ProfileConfig.factoryDefault
            fresh.id = currentID
            fresh.name = currentName
            profile = fresh
        }
    }

    public func setRotaryBinding(
        _ rotary: TourBoxRotary,
        modifier: TourBoxButton? = nil,
        action: RotaryBindingAction
    ) {
        mutateActiveProfile { profile in
            if let mod = modifier {
                let key = ControlStateMachine.RotaryComboKey(modifier: mod, rotary: rotary)
                if action.isNone {
                    profile.rotaryComboBindings.removeValue(forKey: key)
                } else {
                    profile.modifierButtons.insert(mod)
                    profile.rotaryComboBindings[key] = action
                }
            } else {
                if action.isNone {
                    profile.rotaryBindings.removeValue(forKey: rotary)
                } else {
                    profile.rotaryBindings[rotary] = action
                }
            }
        }
    }

    public func setButtonBinding(
        _ button: TourBoxButton,
        modifier: TourBoxButton? = nil,
        action: ButtonBindingAction
    ) {
        mutateActiveProfile { profile in
            if let mod = modifier, mod != button {
                let key = ControlStateMachine.ButtonComboKey(modifier: mod, targetButton: button)
                if action.isNone {
                    profile.buttonComboBindings.removeValue(forKey: key)
                } else {
                    profile.modifierButtons.insert(mod)
                    profile.buttonComboBindings[key] = action
                }
            } else {
                if action.isNone {
                    profile.buttonBindings.removeValue(forKey: button)
                } else {
                    profile.buttonBindings[button] = action
                }
            }
        }
    }

    public func setDoublePressBinding(_ button: TourBoxButton, action: ButtonBindingAction) {
        mutateActiveProfile { profile in
            if action.isNone {
                profile.doublePressBindings.removeValue(forKey: button)
            } else {
                profile.doublePressBindings[button] = action
            }
        }
    }

    public func setModifierButton(_ button: TourBoxButton, isModifier: Bool) {
        mutateActiveProfile { profile in
            if isModifier {
                profile.modifierButtons.insert(button)
            } else {
                profile.modifierButtons.remove(button)
                profile.rotaryComboBindings = profile.rotaryComboBindings.filter { $0.key.modifier != button }
                profile.buttonComboBindings = profile.buttonComboBindings.filter { $0.key.modifier != button }
            }
        }
    }

    // MARK: - Global Preferences Mutation

    public func setShowHUD(_ enabled: Bool) {
        guard configuration.showHUD != enabled else { return }
        configuration.showHUD = enabled
        persistConfigurationIfNeeded()
    }

    public func setShowDbInMenuBar(_ enabled: Bool) {
        guard configuration.showDbInMenuBar != enabled else { return }
        configuration.showDbInMenuBar = enabled
        persistConfigurationIfNeeded()
    }

    public func setAutoSwitchByFrontmostApp(_ enabled: Bool) {
        guard configuration.autoSwitchByFrontmostApp != enabled else { return }
        configuration.autoSwitchByFrontmostApp = enabled
        persistConfigurationIfNeeded()
    }

    public func updateOSCEndpoint(host: String, outgoingPort: UInt16, incomingPort: UInt16) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedHost = trimmedHost.isEmpty ? "127.0.0.1" : trimmedHost
        configuration.oscHost = resolvedHost
        configuration.oscOutgoingPort = outgoingPort
        configuration.oscIncomingPort = incomingPort
        persistConfigurationIfNeeded()
        totalMix.reconfigureTransport(
            host: resolvedHost,
            outgoingPort: outgoingPort,
            incomingPort: incomingPort
        )
    }

    // MARK: - Trigger Execution Engine

    private func executeResolvedTrigger(_ trigger: ResolvedControlTrigger) {
        let profile = activeProfile

        switch trigger {
        case .rotaryTurn(let rotary, let direction, let modifier, let timestamp):
            let action: RotaryBindingAction
            let slotKey: String
            if let mod = modifier {
                let key = ControlStateMachine.RotaryComboKey(modifier: mod, rotary: rotary)
                action = profile.rotaryComboBindings[key] ?? .none
                slotKey = "combo:\(mod.rawValue)+\(rotary.rawValue)"
            } else {
                action = profile.rotaryBindings[rotary] ?? .none
                slotKey = "base:\(rotary.rawValue)"
            }
            executeRotaryAction(action, direction: direction, slotKey: slotKey, timestamp: timestamp)

        case .buttonDown(let button, let modifier):
            let action = resolveButtonAction(in: profile, button: button, modifier: modifier)
            executeButtonDownAction(action)

        case .buttonUp(let button, let modifier):
            let action = resolveButtonAction(in: profile, button: button, modifier: modifier)
            switch action {
            case .keyShortcut(let combo):
                _ = actionExecutor.sendKeyComboUp(combo)
            case .mouseClick(let mouseBtn):
                _ = actionExecutor.sendMouseButtonUp(mouseBtn)
            default:
                break
            }

        case .buttonTapOnRelease(let button):
            let action = profile.buttonBindings[button] ?? .none
            executeOneShotButtonAction(action)

        case .buttonDoublePress(let button):
            let action = profile.doublePressBindings[button] ?? .none
            executeOneShotButtonAction(action)
        }
    }

    private func executeRotaryAction(
        _ action: RotaryBindingAction,
        direction: RotaryDirection,
        slotKey: String,
        timestamp: TimeInterval
    ) {
        switch action {
        case .none:
            return

        case .rmeOutputFader(let channelIndex, let ballistics, let safetyClamp0dB, let safetyMaxDb):
            var state = ballisticsBySlot[slotKey, default: RotaryBallisticsState()]
            let deltaDb = state.step(
                isClockwise: direction.isClockwise,
                timestamp: timestamp,
                config: ballistics
            )
            ballisticsBySlot[slotKey] = state

            let limitDb = VolumeSafetyLimit.clampCeilingDb(safetyMaxDb)
            let stepResult = totalMix.adjustOutputFaderDb(
                channel: channelIndex,
                deltaDb: deltaDb,
                safetyClamp0dB: safetyClamp0dB,
                safetyMaxDb: limitDb
            )

            guard !stepResult.isDeferredColdStart else { return }
            emitOutputFaderHUD(for: stepResult)

        case .rmeSubmixFader(let sourceBus, let sourceIndex, let outputIndex, let ballistics, let safetyClamp0dB, let safetyMaxDb):
            var state = ballisticsBySlot[slotKey, default: RotaryBallisticsState()]
            let deltaDb = state.step(
                isClockwise: direction.isClockwise,
                timestamp: timestamp,
                config: ballistics
            )
            ballisticsBySlot[slotKey] = state

            let canonicalSrc = FirefaceUCXProfile.canonicalControlIndex(
                max(0, sourceIndex),
                in: sourceBus == .input ? totalMix.inputChannels : totalMix.playbackChannels
            )
            let canonicalOut = totalMix.canonicalOutputIndex(outputIndex)
            let routeKey = SubmixRouteKey(
                sourceBus: sourceBus,
                sourceIndex: canonicalSrc,
                outputIndex: canonicalOut
            )
            let currentDb = totalMix.submixRoutes[routeKey]?.dbValue ?? 0.0
            let limitDb = VolumeSafetyLimit.clampCeilingDb(safetyMaxDb)
            let clamped = applySafetyCeilingClamp(
                currentDb: currentDb,
                deltaDb: deltaDb,
                enabled: safetyClamp0dB,
                maxDb: limitDb
            )
            let targetDb = min(RMEFaderCurve.maxDb, max(RMEFaderCurve.minDb, clamped.targetDb))
            let targetNorm = RMEFaderCurve.dbToNormalized(targetDb)
            totalMix.setSubmixFaderNormalized(
                sourceBus: sourceBus,
                sourceIndex: canonicalSrc,
                outputIndex: canonicalOut,
                normalized: targetNorm
            )

            let srcName = channelDisplayName(bus: sourceBus, index: canonicalSrc)
            let dstName = channelDisplayName(bus: .output, index: canonicalOut)
            let limitNorm: Double? = safetyClamp0dB ? RMEFaderCurve.dbToNormalized(limitDb) : nil
            emitHUDIfEnabled(
                CoordinatorHUDEvent(
                    title: "\(srcName) → \(dstName)",
                    subtitle: "Submix Send",
                    dbText: RMEFaderCurve.formatDb(targetDb),
                    normalizedLevel: targetNorm,
                    unityNormalizedPosition: RMEFaderCurve.zeroDbNormalized,
                    safetyLimitNormalizedPosition: limitNorm,
                    isMuted: false,
                    hitZeroDbLock: clamped.hitLimitLock,
                    badgeText: clamped.hitLimitLock ? VolumeSafetyLimit.formatMaxBadge(limitDb) : nil,
                    systemIcon: "slider.vertical.3"
                )
            )

        case .keyPair(let cw, let ccw):
            let combo = direction.isClockwise ? cw : ccw
            _ = actionExecutor.sendKeyComboTap(combo)

        case .mouseScroll(let scrollConfig):
            _ = actionExecutor.sendMouseScroll(
                isPositiveStep: direction.isClockwise,
                config: scrollConfig,
                timestamp: timestamp
            )

        case .systemVolume:
            actionExecutor.triggerMediaKey(direction.isClockwise ? .volumeUp : .volumeDown)
        }
    }

    private func executeButtonDownAction(_ action: ButtonBindingAction) {
        switch action {
        case .keyShortcut(let combo):
            _ = actionExecutor.sendKeyComboDown(combo)
            return
        case .mouseClick(let mouseBtn):
            _ = actionExecutor.sendMouseButtonDown(mouseBtn)
            return
        default:
            break
        }
        executeOneShotButtonAction(action)
    }

    private func executeOneShotButtonAction(_ action: ButtonBindingAction) {
        switch action {
        case .none:
            return

        case .rmeOutputMute(let channelIndex):
            _ = toggleOutputChannelMute(channelIndex: channelIndex)

        case .rmeSetOutputDb(let channelIndex, let targetDb):
            let res = totalMix.setOutputFaderDb(channel: channelIndex, db: targetDb)
            emitHUDIfEnabled(
                CoordinatorHUDEvent(
                    title: res.displayName,
                    subtitle: "Preset Level",
                    dbText: res.isMuted ? "MUTED" : res.formattedDb,
                    normalizedLevel: res.normalizedFader,
                    unityNormalizedPosition: RMEFaderCurve.zeroDbNormalized,
                    isMuted: res.isMuted,
                    hitZeroDbLock: false,
                    badgeText: nil,
                    systemIcon: "speaker.wave.2.fill"
                )
            )

        case .rmeChannelMute(let bus, let channelIndex):
            if bus == .output {
                _ = toggleOutputChannelMute(channelIndex: channelIndex)
            } else {
                let muted = totalMix.toggleChannelMute(bus: bus, channel: channelIndex)
                let title = channelDisplayName(bus: bus, index: channelIndex)
                emitHUDIfEnabled(
                    CoordinatorHUDEvent(
                        title: title,
                        subtitle: bus.displayName,
                        dbText: muted ? "MUTED" : "UNMUTED",
                        normalizedLevel: muted ? 0.0 : RMEFaderCurve.zeroDbNormalized,
                        isMuted: muted,
                        hitZeroDbLock: false,
                        badgeText: muted ? "MUTE" : nil,
                        systemIcon: muted ? "mic.slash.fill" : "mic.fill"
                    )
                )
            }

        case .rmeControlRoom(let fn):
            let active = totalMix.toggleControlRoom(fn)
            emitHUDIfEnabled(
                CoordinatorHUDEvent(
                    title: fn.displayName,
                    subtitle: "Main Out (\(totalMix.mainOutDisplayName))",
                    dbText: fn == .mainRecall ? "RECALL" : (active ? "ON" : "OFF"),
                    normalizedLevel: active ? 1.0 : 0.0,
                    isMuted: fn == .globalMute && active,
                    hitZeroDbLock: false,
                    badgeText: nil,
                    systemIcon: "dial.medium.fill"
                )
            )

        case .rmeSnapshot(let slot):
            totalMix.loadSnapshot(slot)
            emitHUDIfEnabled(
                CoordinatorHUDEvent(
                    title: "Snapshot \(slot)",
                    subtitle: "TotalMix FX",
                    dbText: "LOADED",
                    normalizedLevel: 1.0,
                    systemIcon: "camera.metering.matrix"
                )
            )

        case .rmeLayout(let preset):
            totalMix.loadLayout(preset)
            emitHUDIfEnabled(
                CoordinatorHUDEvent(
                    title: "Layout \(preset)",
                    subtitle: "TotalMix FX",
                    dbText: "APPLIED",
                    normalizedLevel: 1.0,
                    systemIcon: "rectangle.3.group"
                )
            )

        case .rmeToggleWindow:
            _ = totalMix.toggleTotalMixWindow()

        case .keyShortcut(let combo):
            _ = actionExecutor.sendKeyComboTap(combo)

        case .mouseClick(let mouseBtn):
            _ = actionExecutor.sendMouseButtonClick(mouseBtn)

        case .mediaKey(let media):
            actionExecutor.triggerMediaKey(media)

        case .shellCommand(let cmd):
            actionExecutor.executeShellCommandAsync(cmd)

        case .appleScript(let script):
            actionExecutor.executeAppleScriptAsync(script)

        case .cycleProfile:
            cycleToNextProfile()

        case .openKeymapper:
            onOpenKeymapperRequested?()
        }
    }

    private func resolveButtonAction(
        in profile: ProfileConfig,
        button: TourBoxButton,
        modifier: TourBoxButton?
    ) -> ButtonBindingAction {
        if let mod = modifier {
            let key = ControlStateMachine.ButtonComboKey(modifier: mod, targetButton: button)
            return profile.buttonComboBindings[key] ?? .none
        }
        return profile.buttonBindings[button] ?? .none
    }

    // MARK: - Internal Helpers

    private func updatePhysicalHighlight(for decoded: TourBoxDecodedByte) {
        switch decoded {
        case .buttonPress(let btn):
            physicallyHeldButtons.insert(btn)
            activePhysicalControls.insert(btn.controlId)

        case .buttonRelease(let btn):
            physicallyHeldButtons.remove(btn)
            if let rotary = btn.controlId.rotaryControl, rotaryGlowTasks[rotary] != nil {
                // 若对应旋钮正在 150ms 旋转呼吸亮起中，交由防抖任务熄灭
                return
            }
            activePhysicalControls.remove(btn.controlId)

        case .rotaryStep(let rotary, _):
            let controlId = rotary.controlId
            activePhysicalControls.insert(controlId)
            rotaryGlowTasks[rotary]?.cancel()
            rotaryGlowTasks[rotary] = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Self.rotaryGlowDurationMs))
                guard !Task.isCancelled, let self else { return }
                self.rotaryGlowTasks.removeValue(forKey: rotary)
                if !self.physicallyHeldButtons.contains(controlId.buttonControl) {
                    self.activePhysicalControls.remove(controlId)
                }
            }

        case .rotaryStop:
            // 严格遵守 #6：绝不响应 0xC4/0x84/0xC9/0x89 停止码熄灭高亮（否则 2ms 就闪灭不可见）
            break
        }
    }

    private func scheduleDoubleClickDeadlineIfNeeded(referenceNow: TimeInterval) {
        doubleClickTimerTask?.cancel()
        doubleClickTimerTask = nil
        guard let deadline = stateMachine.nextPendingDeadline else { return }
        let waitSec = max(0.005, deadline - referenceNow + 0.002)

        doubleClickTimerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(waitSec))
            guard !Task.isCancelled, let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let triggers = self.stateMachine.advanceTime(now: max(now, deadline + 0.001))
            if self.activeHardwareModifiers != self.stateMachine.activeModifiers {
                self.activeHardwareModifiers = self.stateMachine.activeModifiers
            }
            for trigger in triggers {
                self.executeResolvedTrigger(trigger)
            }
            self.scheduleDoubleClickDeadlineIfNeeded(referenceNow: now)
        }
    }

    private func mutateActiveProfile(_ mutation: (inout ProfileConfig) -> Void) {
        let activeID = activeProfile.id
        if let idx = configuration.profiles.firstIndex(where: { $0.id == activeID }) {
            mutation(&configuration.profiles[idx])
        } else if !configuration.profiles.isEmpty {
            mutation(&configuration.profiles[0])
            configuration.activeProfileId = configuration.profiles[0].id
        }
        rebuildStateMachineConfiguration()
        persistConfigurationIfNeeded()
    }

    private func rebuildStateMachineConfiguration() {
        let profile = activeProfile
        let doubleButtons = Set(
            profile.doublePressBindings.compactMap { key, val in val.isNone ? nil : key }
        )
        let validButtonCombos = Set(
            profile.buttonComboBindings.compactMap { key, val in val.isNone ? nil : key }
        )
        let validRotaryCombos = Set(
            profile.rotaryComboBindings.compactMap { key, val in val.isNone ? nil : key }
        )
        stateMachine.updateConfiguration(
            modifierButtons: profile.modifierButtons,
            doublePressButtons: doubleButtons,
            doubleClickWindowSec: 0.26,
            buttonCombos: validButtonCombos,
            rotaryCombos: validRotaryCombos
        )
    }

    private func persistConfigurationIfNeeded() {
        guard persistChangesToDisk else { return }
        do {
            try configuration.save(to: configFileURL)
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = error.localizedDescription
        }
    }

    private func handleFrontmostAppActivated(bundleIdentifier: String?) {
        guard configuration.autoSwitchByFrontmostApp,
              let bundleID = bundleIdentifier,
              !bundleID.isEmpty,
              bundleID != "com.soundlab.TourMix"
        else {
            return
        }
        if let matched = configuration.profiles.first(where: {
            $0.associatedBundleIdentifier?.caseInsensitiveCompare(bundleID) == .orderedSame
        }) {
            selectProfile(id: matched.id)
        }
    }

    private func releaseAllTransientControlStates() {
        doubleClickTimerTask?.cancel()
        doubleClickTimerTask = nil
        for (_, task) in rotaryGlowTasks {
            task.cancel()
        }
        rotaryGlowTasks.removeAll()
        physicallyHeldButtons.removeAll()
        activePhysicalControls.removeAll()
        ballisticsBySlot.removeAll()

        let releaseTriggers = stateMachine.reset()
        if !activeHardwareModifiers.isEmpty {
            activeHardwareModifiers = []
        }
        for trigger in releaseTriggers {
            if case .buttonUp(let btn, let mod) = trigger {
                let action = resolveButtonAction(in: activeProfile, button: btn, modifier: mod)
                if case .keyShortcut(let combo) = action {
                    _ = actionExecutor.sendKeyComboUp(combo)
                }
            }
        }
        actionExecutor.releaseAllHeldKeys()
    }

    private func stopConsumersAndObservers() {
        serialConsumerTask?.cancel()
        serialConsumerTask = nil
        doubleClickTimerTask?.cancel()
        doubleClickTimerTask = nil

        let wsCenter = NSWorkspace.shared.notificationCenter
        if let workspaceActivateObserver {
            wsCenter.removeObserver(workspaceActivateObserver)
            self.workspaceActivateObserver = nil
        }
        if let workspaceSleepObserver {
            wsCenter.removeObserver(workspaceSleepObserver)
            self.workspaceSleepObserver = nil
        }
    }

    private func emitOutputFaderHUD(for stepResult: FaderStepResult) {
        let limitNorm = stepResult.safetyMaxDb.map {
            RMEFaderCurve.dbToNormalized(VolumeSafetyLimit.clampCeilingDb($0))
        }
        let badgeText: String? = stepResult.hitZeroDbLock
            ? VolumeSafetyLimit.formatMaxBadge(stepResult.safetyMaxDb ?? 0.0)
            : nil
        emitHUDIfEnabled(
            CoordinatorHUDEvent(
                title: stepResult.displayName,
                subtitle: "Hardware Output",
                dbText: stepResult.isMuted ? "MUTED" : stepResult.formattedDb,
                normalizedLevel: stepResult.normalizedFader,
                unityNormalizedPosition: RMEFaderCurve.zeroDbNormalized,
                safetyLimitNormalizedPosition: limitNorm,
                isMuted: stepResult.isMuted,
                hitZeroDbLock: stepResult.hitZeroDbLock,
                badgeText: badgeText,
                systemIcon: stepResult.isMuted ? "speaker.slash.fill" : "hifispeaker.2.fill"
            )
        )
    }

    private func emitHUDIfEnabled(_ event: CoordinatorHUDEvent) {
        guard configuration.showHUD else { return }
        onHUDEvent?(event)
    }

    private func appendSerialDiagnostic(
        direction: String,
        hex: String,
        note: String,
        timestamp: TimeInterval
    ) {
        serialDiagnostics.append(
            SerialDiagnosticEntry(
                direction: direction,
                hex: hex,
                note: note,
                timestamp: timestamp
            )
        )
        let cap = isDiagnosticsCaptureEnabled ? Self.maxSerialDiagnostics : Self.maxBackgroundSystemDiagnostics
        if serialDiagnostics.count > cap {
            serialDiagnostics.removeFirst(serialDiagnostics.count - cap)
        }
    }
}
