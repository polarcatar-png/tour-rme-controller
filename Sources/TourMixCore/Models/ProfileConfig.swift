import Foundation

/// 旋钮 / 滚轮旋转可绑定的动作类型。
public enum RotaryBindingAction: Codable, Equatable, Sendable {
    case none
    case rmeOutputFader(
        channelIndex: Int,
        ballistics: RotaryBallisticsConfig,
        safetyClamp0dB: Bool,
        safetyMaxDb: Double = VolumeSafetyLimit.defaultMaxDb
    )
    case rmeSubmixFader(
        sourceBus: MixerBus,
        sourceIndex: Int,
        outputIndex: Int,
        ballistics: RotaryBallisticsConfig,
        safetyClamp0dB: Bool,
        safetyMaxDb: Double = VolumeSafetyLimit.defaultMaxDb
    )
    case keyPair(cw: KeyCombo, ccw: KeyCombo)
    case mouseScroll(MouseScrollConfig)
    case systemVolume

    private enum OuterCodingKeys: String, CodingKey {
        case none
        case rmeOutputFader
        case rmeSubmixFader
        case keyPair
        case mouseScroll
        case systemVolume
    }

    private enum OutputFaderKeys: String, CodingKey {
        case channelIndex
        case ballistics
        case safetyClamp0dB
        case safetyMaxDb
    }

    private enum SubmixFaderKeys: String, CodingKey {
        case sourceBus
        case sourceIndex
        case outputIndex
        case ballistics
        case safetyClamp0dB
        case safetyMaxDb
    }

    private enum KeyPairKeys: String, CodingKey {
        case cw
        case ccw
    }

    private enum MouseScrollKeys: String, CodingKey {
        case _0
    }

    private enum EmptyKeys: String, CodingKey {
        case unused
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: OuterCodingKeys.self)
        guard let matchedKey = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "RotaryBindingAction 缺少动作类型键"
                )
            )
        }

        switch matchedKey {
        case .none:
            _ = try? container.nestedContainer(keyedBy: EmptyKeys.self, forKey: .none)
            self = .none

        case .rmeOutputFader:
            let nested = try container.nestedContainer(keyedBy: OutputFaderKeys.self, forKey: .rmeOutputFader)
            let channelIndex = try nested.decode(Int.self, forKey: .channelIndex)
            let ballistics = try nested.decode(RotaryBallisticsConfig.self, forKey: .ballistics)
            let safetyClamp = try nested.decode(Bool.self, forKey: .safetyClamp0dB)
            let rawMaxDb = try nested.decodeIfPresent(Double.self, forKey: .safetyMaxDb)
            let safetyMaxDb = VolumeSafetyLimit.clampCeilingDb(rawMaxDb ?? VolumeSafetyLimit.defaultMaxDb)
            self = .rmeOutputFader(
                channelIndex: channelIndex,
                ballistics: ballistics,
                safetyClamp0dB: safetyClamp,
                safetyMaxDb: safetyMaxDb
            )

        case .rmeSubmixFader:
            let nested = try container.nestedContainer(keyedBy: SubmixFaderKeys.self, forKey: .rmeSubmixFader)
            let sourceBus = try nested.decode(MixerBus.self, forKey: .sourceBus)
            let sourceIndex = try nested.decode(Int.self, forKey: .sourceIndex)
            let outputIndex = try nested.decode(Int.self, forKey: .outputIndex)
            let ballistics = try nested.decode(RotaryBallisticsConfig.self, forKey: .ballistics)
            let safetyClamp = try nested.decode(Bool.self, forKey: .safetyClamp0dB)
            let rawMaxDb = try nested.decodeIfPresent(Double.self, forKey: .safetyMaxDb)
            let safetyMaxDb = VolumeSafetyLimit.clampCeilingDb(rawMaxDb ?? VolumeSafetyLimit.defaultMaxDb)
            self = .rmeSubmixFader(
                sourceBus: sourceBus,
                sourceIndex: sourceIndex,
                outputIndex: outputIndex,
                ballistics: ballistics,
                safetyClamp0dB: safetyClamp,
                safetyMaxDb: safetyMaxDb
            )

        case .keyPair:
            let nested = try container.nestedContainer(keyedBy: KeyPairKeys.self, forKey: .keyPair)
            let cw = try nested.decode(KeyCombo.self, forKey: .cw)
            let ccw = try nested.decode(KeyCombo.self, forKey: .ccw)
            self = .keyPair(cw: cw, ccw: ccw)

        case .mouseScroll:
            let nested = try container.nestedContainer(keyedBy: MouseScrollKeys.self, forKey: .mouseScroll)
            let cfg = try nested.decode(MouseScrollConfig.self, forKey: ._0)
            self = .mouseScroll(cfg)

        case .systemVolume:
            _ = try? container.nestedContainer(keyedBy: EmptyKeys.self, forKey: .systemVolume)
            self = .systemVolume
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: OuterCodingKeys.self)
        switch self {
        case .none:
            _ = container.nestedContainer(keyedBy: EmptyKeys.self, forKey: .none)

        case .rmeOutputFader(let channelIndex, let ballistics, let safetyClamp, let safetyMaxDb):
            var nested = container.nestedContainer(keyedBy: OutputFaderKeys.self, forKey: .rmeOutputFader)
            try nested.encode(channelIndex, forKey: .channelIndex)
            try nested.encode(ballistics, forKey: .ballistics)
            try nested.encode(safetyClamp, forKey: .safetyClamp0dB)
            try nested.encode(VolumeSafetyLimit.clampCeilingDb(safetyMaxDb), forKey: .safetyMaxDb)

        case .rmeSubmixFader(let sourceBus, let sourceIndex, let outputIndex, let ballistics, let safetyClamp, let safetyMaxDb):
            var nested = container.nestedContainer(keyedBy: SubmixFaderKeys.self, forKey: .rmeSubmixFader)
            try nested.encode(sourceBus, forKey: .sourceBus)
            try nested.encode(sourceIndex, forKey: .sourceIndex)
            try nested.encode(outputIndex, forKey: .outputIndex)
            try nested.encode(ballistics, forKey: .ballistics)
            try nested.encode(safetyClamp, forKey: .safetyClamp0dB)
            try nested.encode(VolumeSafetyLimit.clampCeilingDb(safetyMaxDb), forKey: .safetyMaxDb)

        case .keyPair(let cw, let ccw):
            var nested = container.nestedContainer(keyedBy: KeyPairKeys.self, forKey: .keyPair)
            try nested.encode(cw, forKey: .cw)
            try nested.encode(ccw, forKey: .ccw)

        case .mouseScroll(let cfg):
            var nested = container.nestedContainer(keyedBy: MouseScrollKeys.self, forKey: .mouseScroll)
            try nested.encode(cfg, forKey: ._0)

        case .systemVolume:
            _ = container.nestedContainer(keyedBy: EmptyKeys.self, forKey: .systemVolume)
        }
    }

    public var isNone: Bool {
        if case .none = self { return true }
        return false
    }

    public var requiresAccessibility: Bool {
        switch self {
        case .keyPair, .mouseScroll:
            return true
        default:
            return false
        }
    }

    /// 生成面向画布徽章与检查器的简明中文摘要；未绑定返回 `nil`。
    public func summaryText(channelNameResolver: (MixerBus, Int) -> String) -> String? {
        switch self {
        case .none:
            return nil
        case .rmeOutputFader(let channelIndex, _, _, _):
            return "\(channelNameResolver(.output, channelIndex)) 音量"
        case .rmeSubmixFader(let sourceBus, let sourceIndex, let outputIndex, _, _, _):
            let src = channelNameResolver(sourceBus, sourceIndex)
            let dst = channelNameResolver(.output, outputIndex)
            return "\(src) → \(dst)"
        case .keyPair(let cw, let ccw):
            return "\(ccw.displayLabel) / \(cw.displayLabel)"
        case .mouseScroll(let cfg):
            let axisText = cfg.axis == .vertical ? "上下" : "左右"
            return cfg.mode == .trackpadSmooth ? "平滑\(axisText)滚动" : "鼠标\(axisText)滚轮"
        case .systemVolume:
            return "系统音量"
        }
    }
}

/// 物理按键（单击 / 双击 / 修饰键组合）可绑定的动作类型。
public enum ButtonBindingAction: Codable, Equatable, Sendable {
    case none
    case rmeOutputMute(channelIndex: Int)
    case rmeSetOutputDb(channelIndex: Int, targetDb: Double)
    case rmeChannelMute(bus: MixerBus, channelIndex: Int)
    case rmeControlRoom(ControlRoomFunction)
    case rmeSnapshot(Int) // 1...8 (1-based)
    case rmeLayout(Int)   // 1...6 (1-based)
    case rmeToggleWindow
    case keyShortcut(KeyCombo)
    case mouseClick(MouseClickButton)
    case mediaKey(MediaKeyAction)
    case shellCommand(String)
    case appleScript(String)
    case cycleProfile
    case openKeymapper

    public var isNone: Bool {
        if case .none = self { return true }
        return false
    }

    /// 是否需要 macOS 辅助功能权限（键盘快捷键或鼠标点击合成需要）。
    public var requiresAccessibility: Bool {
        switch self {
        case .keyShortcut, .mouseClick:
            return true
        default:
            return false
        }
    }

    /// 生成面向画布徽章与检查器的简明中文摘要；未绑定返回 `nil`。
    public func summaryText(channelNameResolver: (MixerBus, Int) -> String) -> String? {
        switch self {
        case .none:
            return nil
        case .rmeOutputMute(let channelIndex):
            return "\(channelNameResolver(.output, channelIndex)) 静音"
        case .rmeSetOutputDb(let channelIndex, let targetDb):
            return "\(channelNameResolver(.output, channelIndex)) \(RMEFaderCurve.formatDb(targetDb))"
        case .rmeChannelMute(let bus, let channelIndex):
            return "\(channelNameResolver(bus, channelIndex)) 静音"
        case .rmeControlRoom(let fn):
            switch fn {
            case .dim: return "Main Dim"
            case .mono: return "Main Mono"
            case .speakerB: return "Speaker B"
            case .talkback: return "Talkback"
            case .globalMute: return "全局静音"
            case .mainRecall: return "Main Recall"
            }
        case .rmeSnapshot(let slot):
            return "快照 \(slot)"
        case .rmeLayout(let preset):
            return "布局 \(preset)"
        case .rmeToggleWindow:
            return "TotalMix 窗口"
        case .keyShortcut(let combo):
            return combo.displayLabel
        case .mouseClick(let btn):
            return btn.shortSummary
        case .mediaKey(let media):
            return media.displayName
        case .shellCommand(let cmd):
            let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Shell 命令" : "Shell: \(trimmed.prefix(14))"
        case .appleScript:
            return "AppleScript"
        case .cycleProfile:
            return "切换预设"
        case .openKeymapper:
            return "打开配置台"
        }
    }
}

/// 单套按键与旋钮映射预设模型。
public struct ProfileConfig: Codable, Equatable, Identifiable, Sendable {
    public static let factoryDefaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    public var id: UUID
    public var name: String
    /// 可选关联的前台应用 Bundle ID（例如 `"com.apple.logic10"`），用于自动切换预设。
    public var associatedBundleIdentifier: String?

    /// 基础层旋钮绑定
    public var rotaryBindings: [TourBoxRotary: RotaryBindingAction]
    /// 基础层按键单击绑定
    public var buttonBindings: [TourBoxButton: ButtonBindingAction]
    /// 按键双击绑定
    public var doublePressBindings: [TourBoxButton: ButtonBindingAction]
    /// 被设为硬件修饰键（如 Fn）的按钮集合
    public var modifierButtons: Set<TourBoxButton>
    /// 「硬件修饰键 + 旋钮」组合绑定
    public var rotaryComboBindings: [ControlStateMachine.RotaryComboKey: RotaryBindingAction]
    /// 「硬件修饰键 + 目标按键」组合绑定
    public var buttonComboBindings: [ControlStateMachine.ButtonComboKey: ButtonBindingAction]

    public init(
        id: UUID = UUID(),
        name: String,
        associatedBundleIdentifier: String? = nil,
        rotaryBindings: [TourBoxRotary: RotaryBindingAction] = [:],
        buttonBindings: [TourBoxButton: ButtonBindingAction] = [:],
        doublePressBindings: [TourBoxButton: ButtonBindingAction] = [:],
        modifierButtons: Set<TourBoxButton> = [],
        rotaryComboBindings: [ControlStateMachine.RotaryComboKey: RotaryBindingAction] = [:],
        buttonComboBindings: [ControlStateMachine.ButtonComboKey: ButtonBindingAction] = [:]
    ) {
        self.id = id
        self.name = name
        self.associatedBundleIdentifier = associatedBundleIdentifier
        self.rotaryBindings = rotaryBindings
        self.buttonBindings = buttonBindings
        self.doublePressBindings = doublePressBindings
        self.modifierButtons = modifierButtons
        self.rotaryComboBindings = rotaryComboBindings
        self.buttonComboBindings = buttonComboBindings
    }

    /// 极简纯净的出厂默认预设：
    /// - **唯一绑定**：`Knob 旋转 -> 硬件输出 AN 1/2 (索引 0)，标准三级动态加速，开启 0.0 dB 安全限位`；
    /// - 其余所有旋钮（`scroll`）、按键（含 `knobClick`、`scrollClick` 及 6 颗物理键）、修饰键与组合键一律留空。
    public static var factoryDefault: ProfileConfig {
        ProfileConfig(
            id: factoryDefaultID,
            name: "默认监听 (AN 1/2)",
            associatedBundleIdentifier: nil,
            rotaryBindings: [
                .knob: .rmeOutputFader(
                    channelIndex: 0,
                    ballistics: .standard,
                    safetyClamp0dB: true
                ),
            ],
            buttonBindings: [:],
            doublePressBindings: [:],
            modifierButtons: [],
            rotaryComboBindings: [:],
            buttonComboBindings: [:]
        )
    }

    /// 按确定性顺序提取当前预设绑定的去重硬件输出通道列表（供菜单栏面板自适应渲染 `1..N` 张通道卡片）。
    public var boundOutputChannels: [(channelIndex: Int, safetyClamp0dB: Bool, safetyMaxDb: Double)] {
        var result: [(channelIndex: Int, safetyClamp0dB: Bool, safetyMaxDb: Double)] = []
        var indexPositionMap: [Int: Int] = [:]

        func upsert(channel: Int, safetyClamp: Bool, safetyMaxDb: Double, overwriteClamp: Bool) {
            guard channel >= 0 else { return }
            let clampedLimit = VolumeSafetyLimit.clampCeilingDb(safetyMaxDb)
            if let existingPos = indexPositionMap[channel] {
                if overwriteClamp {
                    result[existingPos] = (
                        channelIndex: channel,
                        safetyClamp0dB: safetyClamp,
                        safetyMaxDb: clampedLimit
                    )
                }
            } else {
                indexPositionMap[channel] = result.count
                result.append((
                    channelIndex: channel,
                    safetyClamp0dB: safetyClamp,
                    safetyMaxDb: clampedLimit
                ))
            }
        }

        // 1. 基础层旋钮（按 Knob -> Scroll 顺序）
        for rotary in TourBoxRotary.allCases {
            if case .rmeOutputFader(let ch, _, let clamp, let maxDb) = rotaryBindings[rotary] {
                upsert(channel: ch, safetyClamp: clamp, safetyMaxDb: maxDb, overwriteClamp: true)
            }
        }

        // 2. 修饰键 + 旋钮组合（按固定枚举序）
        for mod in TourBoxButton.allCases {
            for rotary in TourBoxRotary.allCases {
                let key = ControlStateMachine.RotaryComboKey(modifier: mod, rotary: rotary)
                if case .rmeOutputFader(let ch, _, let clamp, let maxDb) = rotaryComboBindings[key] {
                    upsert(channel: ch, safetyClamp: clamp, safetyMaxDb: maxDb, overwriteClamp: false)
                }
            }
        }

        // 3. 按键直接绑定的输出静音或输出定值动作
        for button in TourBoxButton.allCases {
            if let action = buttonBindings[button] {
                extractOutputChannel(from: action) { ch in
                    upsert(
                        channel: ch,
                        safetyClamp: true,
                        safetyMaxDb: VolumeSafetyLimit.defaultMaxDb,
                        overwriteClamp: false
                    )
                }
            }
            if let action = doublePressBindings[button] {
                extractOutputChannel(from: action) { ch in
                    upsert(
                        channel: ch,
                        safetyClamp: true,
                        safetyMaxDb: VolumeSafetyLimit.defaultMaxDb,
                        overwriteClamp: false
                    )
                }
            }
        }

        for mod in TourBoxButton.allCases {
            for btn in TourBoxButton.allCases {
                let key = ControlStateMachine.ButtonComboKey(modifier: mod, targetButton: btn)
                if let action = buttonComboBindings[key] {
                    extractOutputChannel(from: action) { ch in
                        upsert(
                            channel: ch,
                            safetyClamp: true,
                            safetyMaxDb: VolumeSafetyLimit.defaultMaxDb,
                            overwriteClamp: false
                        )
                    }
                }
            }
        }

        return result
    }

    /// 是否包含任何需要 macOS 辅助功能权限的键盘快捷键绑定。
    public var containsKeyboardShortcutBindings: Bool {
        if rotaryBindings.values.contains(where: \.requiresAccessibility) { return true }
        if rotaryComboBindings.values.contains(where: \.requiresAccessibility) { return true }
        if buttonBindings.values.contains(where: \.requiresAccessibility) { return true }
        if doublePressBindings.values.contains(where: \.requiresAccessibility) { return true }
        if buttonComboBindings.values.contains(where: \.requiresAccessibility) { return true }
        return false
    }

    /// 生成单个物理控件区域在当前修饰键状态下的主/副功能标签摘要（供 `TourBoxLiteCanvas` 渲染）。
    public func bindingSummary(
        for control: TourBoxControlId,
        activeModifier: TourBoxButton? = nil,
        channelNameResolver: (MixerBus, Int) -> String
    ) -> (primary: String?, secondary: String?) {
        // 含旋转编码器的复合控件（Knob / Scroll）
        if let rotary = control.rotaryControl {
            let clickBtn = control.buttonControl
            if let mod = activeModifier {
                if clickBtn == mod {
                    let tap = buttonBindings[mod]?.summaryText(channelNameResolver: channelNameResolver)
                    return (primary: "修饰键 (按住)", secondary: tap)
                }
                let rKey = ControlStateMachine.RotaryComboKey(modifier: mod, rotary: rotary)
                let bKey = ControlStateMachine.ButtonComboKey(modifier: mod, targetButton: clickBtn)
                let rText = rotaryComboBindings[rKey]?.summaryText(channelNameResolver: channelNameResolver)
                let bText = buttonComboBindings[bKey]?.summaryText(channelNameResolver: channelNameResolver)
                return (primary: rText, secondary: bText)
            } else {
                let rText = rotaryBindings[rotary]?.summaryText(channelNameResolver: channelNameResolver)
                let bTap = buttonBindings[clickBtn]?.summaryText(channelNameResolver: channelNameResolver)
                let bDouble = doublePressBindings[clickBtn]?.summaryText(channelNameResolver: channelNameResolver)
                let secondary = bTap ?? bDouble.map { "双击: \($0)" }
                return (primary: rText, secondary: secondary)
            }
        }

        // 纯按键控件（Top / Tall / Short / C1 / C2 / Tour）
        let button = control.buttonControl
        if let mod = activeModifier {
            if button == mod {
                let tap = buttonBindings[mod]?.summaryText(channelNameResolver: channelNameResolver)
                return (primary: "修饰键 (按住)", secondary: tap)
            }
            let key = ControlStateMachine.ButtonComboKey(modifier: mod, targetButton: button)
            let comboText = buttonComboBindings[key]?.summaryText(channelNameResolver: channelNameResolver)
            return (primary: comboText, secondary: nil)
        }

        let tapText = buttonBindings[button]?.summaryText(channelNameResolver: channelNameResolver)
        let doubleText = doublePressBindings[button]?.summaryText(channelNameResolver: channelNameResolver)

        if modifierButtons.contains(button) {
            if let tapText {
                return (primary: tapText, secondary: "硬件修饰键")
            }
            return (primary: "硬件修饰键", secondary: doubleText.map { "双击: \($0)" })
        }

        return (primary: tapText, secondary: doubleText.map { "双击: \($0)" })
    }

    /// 一次性生成全部 8 个机身控件区域的标签摘要字典（可直接传给 `TourBoxLiteCanvas`）。
    public func allBindingSummaries(
        activeModifier: TourBoxButton? = nil,
        channelNameResolver: (MixerBus, Int) -> String
    ) -> [TourBoxControlId: (primary: String?, secondary: String?)] {
        var map: [TourBoxControlId: (primary: String?, secondary: String?)] = [:]
        for control in TourBoxControlId.allCases {
            map[control] = bindingSummary(
                for: control,
                activeModifier: activeModifier,
                channelNameResolver: channelNameResolver
            )
        }
        return map
    }

    // MARK: - Helpers

    private func extractOutputChannel(from action: ButtonBindingAction, yield: (Int) -> Void) {
        switch action {
        case .rmeOutputMute(let channelIndex), .rmeSetOutputDb(let channelIndex, _):
            yield(channelIndex)
        case .rmeChannelMute(let bus, let channelIndex) where bus == .output:
            yield(channelIndex)
        default:
            break
        }
    }
}

/// 应用全局持久化配置（存储于 `~/Library/Application Support/TourMix/config.json`）。
public struct AppConfiguration: Codable, Equatable, Sendable {
    public var profiles: [ProfileConfig]
    public var activeProfileId: UUID
    public var autoSwitchByFrontmostApp: Bool
    public var showHUD: Bool
    public var showDbInMenuBar: Bool
    public var oscHost: String
    public var oscOutgoingPort: UInt16
    public var oscIncomingPort: UInt16

    public init(
        profiles: [ProfileConfig],
        activeProfileId: UUID,
        autoSwitchByFrontmostApp: Bool = true,
        showHUD: Bool = true,
        showDbInMenuBar: Bool = false,
        oscHost: String = "127.0.0.1",
        oscOutgoingPort: UInt16 = 7001,
        oscIncomingPort: UInt16 = 9001
    ) {
        let validProfiles = profiles.isEmpty ? [.factoryDefault] : profiles
        self.profiles = validProfiles
        if validProfiles.contains(where: { $0.id == activeProfileId }) {
            self.activeProfileId = activeProfileId
        } else {
            self.activeProfileId = validProfiles[0].id
        }
        self.autoSwitchByFrontmostApp = autoSwitchByFrontmostApp
        self.showHUD = showHUD
        self.showDbInMenuBar = showDbInMenuBar
        self.oscHost = oscHost
        self.oscOutgoingPort = oscOutgoingPort
        self.oscIncomingPort = oscIncomingPort
    }

    public static var factoryDefault: AppConfiguration {
        let defaultProfile = ProfileConfig.factoryDefault
        return AppConfiguration(
            profiles: [defaultProfile],
            activeProfileId: defaultProfile.id,
            autoSwitchByFrontmostApp: true,
            showHUD: true,
            showDbInMenuBar: false,
            oscHost: "127.0.0.1",
            oscOutgoingPort: 7001,
            oscIncomingPort: 9001
        )
    }

    /// 默认配置文件路径：`~/Library/Application Support/TourMix/config.json`
    public static var defaultConfigFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("TourMix", isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
    }

    /// 从磁盘读取配置；若文件不存在或格式损坏，安全回退为 `.factoryDefault`。
    public static func load(from fileURL: URL? = nil) -> AppConfiguration {
        let url = fileURL ?? defaultConfigFileURL
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return .factoryDefault
        }
        guard var decoded = try? JSONDecoder().decode(AppConfiguration.self, from: data) else {
            return .factoryDefault
        }
        if decoded.profiles.isEmpty {
            decoded.profiles = [.factoryDefault]
        }
        if !decoded.profiles.contains(where: { $0.id == decoded.activeProfileId }) {
            decoded.activeProfileId = decoded.profiles[0].id
        }
        return decoded
    }

    /// 原子写入配置至 `~/Library/Application Support/TourMix/config.json`。
    public func save(to fileURL: URL? = nil) throws {
        let url = fileURL ?? Self.defaultConfigFileURL
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: [.atomic])
    }
}
