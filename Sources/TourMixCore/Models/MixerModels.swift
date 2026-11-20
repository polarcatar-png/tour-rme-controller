import Foundation

/// TotalMix FX 三大物理/软件混音总线（物理索引均为 `0-based`）。
public enum MixerBus: String, Codable, CaseIterable, Sendable {
    case input
    case playback
    case output

    /// 中文/双语显示标题。
    public var displayName: String {
        switch self {
        case .input:
            return "硬件输入 (Inputs)"
        case .playback:
            return "软件回放 (Playbacks)"
        case .output:
            return "硬件输出 (Outputs)"
        }
    }

    /// Global OSC 通道路径前缀段（`input` / `playback` / `output`）。
    public var oscChannelSegment: String {
        rawValue
    }

    /// Global OSC 子混音路径段（`/mix/{in|pb}/{src}/{out}/*`），`output` 无子混音音源段。
    public var oscMixSourceSegment: String? {
        switch self {
        case .input:
            return "in"
        case .playback:
            return "pb"
        case .output:
            return nil
        }
    }
}

/// 唯一标识某一混音总线上的 0-based 通道。
public struct MixerChannelID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let bus: MixerBus
    public let index: Int

    public init(bus: MixerBus, index: Int) {
        self.bus = bus
        self.index = index
    }

    public var description: String {
        "\(bus.rawValue):\(index)"
    }
}

/// TotalMix FX 单个通道（或立体声左声道主控槽位）的实时状态。
public struct MixerChannelState: Identifiable, Equatable, Sendable {
    public var id: MixerChannelID {
        MixerChannelID(bus: bus, index: index)
    }

    /// 0-based 物理通道索引（Fireface UCX 为 `0...17`）。
    public let index: Int
    public let bus: MixerBus
    /// TotalMix 原始上报的通道名称（可能为空字符串 `""` 或单声道默认名如 `"AN 1"`）。
    public var rawName: String
    /// 经过立体声对与硬件画像兜底合并后的最终 UI 展示名称（如 `"AN 1/2"`、`"PH 7/8"`）。
    public var displayName: String
    /// 是否处于立体声合并状态（针对偶数通道 `2k`）。
    public var isStereo: Bool
    /// 当偶数通道 `2k` 的 `isStereo == true` 时，奇数右声道 `2k+1` 标记为隐藏配对通道。
    public var isHiddenPartner: Bool
    /// TotalMix 通道颜色索引（`0` 在 Global OSC 动态发现中表示隐藏/不可用通道）。
    public var color: Int
    /// 归一化推子位置 `0.0 ... 1.0`。
    public var normalizedFader: Double
    /// 对应分贝值 `-65.0 ... +6.0 dB`。
    public var dbValue: Double
    /// 格式化后的分贝文本（如 `"-12.5 dB"`、`"0.0 dB"`、`"-∞ dB"`）。
    public var formattedDb: String
    /// 通道独立静音状态（对应 `/{bus}/{ch}/mute`）。
    public var isMuted: Bool
    /// 是否已收到来自 TotalMix 的权威数值确认（用于冷启动防跳变保护）。
    public var hasConfirmedValue: Bool

    public init(
        index: Int,
        bus: MixerBus,
        rawName: String = "",
        displayName: String,
        isStereo: Bool = true,
        isHiddenPartner: Bool = false,
        color: Int = 1,
        normalizedFader: Double = 0.0,
        dbValue: Double = RMEFaderCurve.minDb,
        formattedDb: String = "-∞ dB",
        isMuted: Bool = false,
        hasConfirmedValue: Bool = false
    ) {
        self.index = index
        self.bus = bus
        self.rawName = rawName
        self.displayName = displayName
        self.isStereo = isStereo
        self.isHiddenPartner = isHiddenPartner
        self.color = color
        self.normalizedFader = normalizedFader
        self.dbValue = dbValue
        self.formattedDb = formattedDb
        self.isMuted = isMuted
        self.hasConfirmedValue = hasConfirmedValue
    }
}

/// 子混音路由键（`/mix/{in|pb}/{sourceIndex}/{outputIndex}/*`）。
public struct SubmixRouteKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public let sourceBus: MixerBus
    public let sourceIndex: Int
    public let outputIndex: Int

    public init(sourceBus: MixerBus, sourceIndex: Int, outputIndex: Int) {
        self.sourceBus = sourceBus
        self.sourceIndex = sourceIndex
        self.outputIndex = outputIndex
    }

    public var description: String {
        "\(sourceBus.rawValue):\(sourceIndex)->out:\(outputIndex)"
    }
}

/// 子混音路由推子状态。
public struct SubmixRouteState: Identifiable, Equatable, Sendable {
    public var id: SubmixRouteKey { key }

    public let key: SubmixRouteKey
    public var normalizedFader: Double
    public var dbValue: Double
    public var formattedDb: String
    public var hasConfirmedValue: Bool

    public init(
        key: SubmixRouteKey,
        normalizedFader: Double = 0.0,
        dbValue: Double = RMEFaderCurve.minDb,
        formattedDb: String = "-∞ dB",
        hasConfirmedValue: Bool = false
    ) {
        self.key = key
        self.normalizedFader = normalizedFader
        self.dbValue = dbValue
        self.formattedDb = formattedDb
        self.hasConfirmedValue = hasConfirmedValue
    }
}

/// TotalMix Control Room（监听室）及全局开关枚举。
///
/// 注意：`dim` / `mono` / `speakerB` / `talkback` / `mainRecall` 作用于 TotalMix Control Room 的 `Main Out` 通道，
/// 而单通道静音请使用 `/output/{ch}/mute`（如 `AN 1/2` 对应 `/output/0/mute`）。
public enum ControlRoomFunction: String, Codable, CaseIterable, Sendable {
    case dim
    case mono
    case speakerB
    case talkback
    case globalMute
    case mainRecall

    /// 对应的 Global OSC 路径。
    public var oscAddress: String {
        switch self {
        case .dim:
            return "/controlroom/dim"
        case .mono:
            return "/controlroom/mainmono"
        case .speakerB:
            return "/controlroom/speakerb"
        case .talkback:
            return "/controlroom/talkback"
        case .globalMute:
            return "/globalmute"
        case .mainRecall:
            return "/controlroom/recall"
        }
    }

    /// UI 展示名称。
    public var displayName: String {
        switch self {
        case .dim:
            return "监听室衰减 (Main Out Dim)"
        case .mono:
            return "监听室单声道 (Main Out Mono)"
        case .speakerB:
            return "副监听切换 (Speaker B)"
        case .talkback:
            return "对讲开关 (Talkback)"
        case .globalMute:
            return "全局总静音 (Global Mute)"
        case .mainRecall:
            return "召回参考音量 (Main Recall)"
        }
    }
}

/// TotalMix Control Room 监听室与全局快照状态。
public struct ControlRoomState: Equatable, Sendable {
    /// Control Room 当前分配的 `Main Out` 0-based 输出通道索引（例如 `0 = AN 1/2`, `6 = PH 7/8`）。
    public var mainOutChannelIndex: Int
    public var dim: Bool
    public var mono: Bool
    public var speakerB: Bool
    public var talkback: Bool
    public var globalMute: Bool
    /// 当前激活的快照槽位（`1...8`，`1-based`）。
    public var activeSnapshot: Int?

    public init(
        mainOutChannelIndex: Int = 0,
        dim: Bool = false,
        mono: Bool = false,
        speakerB: Bool = false,
        talkback: Bool = false,
        globalMute: Bool = false,
        activeSnapshot: Int? = nil
    ) {
        self.mainOutChannelIndex = mainOutChannelIndex
        self.dim = dim
        self.mono = mono
        self.speakerB = speakerB
        self.talkback = talkback
        self.globalMute = globalMute
        self.activeSnapshot = activeSnapshot
    }
}

/// 推子步进或设值操作的同步执行结果（供 `CoordinatorEngine` 与无焦点 HUD 直接渲染）。
public struct FaderStepResult: Equatable, Sendable {
    /// 实际生效的目标通道索引（立体声对已归并至偶数左声道 `2k`）。
    public let channelIndex: Int
    /// 通道显示名（如 `"AN 1/2"`）。
    public let displayName: String
    /// 变更后的归一化位置 `0.0 ... 1.0`。
    public let normalizedFader: Double
    /// 变更后的分贝数值 `-65.0 ... +6.0`。
    public let dbValue: Double
    /// 变更后的格式化分贝文本。
    public let formattedDb: String
    /// 本次顺时针步进是否触发了 `0.0 dB` 安全限位锁。
    public let hitZeroDbLock: Bool
    /// 若通道尚未收到 TotalMix 初始音量确认（`hasConfirmedValue == false`），
    /// 本次增量已暂存并触发 `/sendchan/output/{ch}`，此时为 `true`（未盲目发送绝对值）。
    public let isDeferredColdStart: Bool
    /// 当前通道静音状态。
    public let isMuted: Bool

    public init(
        channelIndex: Int,
        displayName: String,
        normalizedFader: Double,
        dbValue: Double,
        formattedDb: String,
        hitZeroDbLock: Bool = false,
        isDeferredColdStart: Bool = false,
        isMuted: Bool = false
    ) {
        self.channelIndex = channelIndex
        self.displayName = displayName
        self.normalizedFader = normalizedFader
        self.dbValue = dbValue
        self.formattedDb = formattedDb
        self.hitZeroDbLock = hitZeroDbLock
        self.isDeferredColdStart = isDeferredColdStart
        self.isMuted = isMuted
    }
}

/// RME Fireface UCX 18 进 / 18 回放 / 18 出物理通道画像与立体声配对命名规则。
public enum FirefaceUCXProfile: Sendable {
    public static let deviceID = "fireface-ucx"
    public static let deviceLabel = "Fireface UCX"
    public static let channelCount = 18

    /// 18 路硬件输入单声道默认标签 (`0..17`)：
    /// `0..7`: `AN 1..8`, `8..9`: `SPDIF L/R`, `10..17`: `ADAT 1..8`
    public static let inputMonoLabels: [String] = [
        "AN 1", "AN 2", "AN 3", "AN 4", "AN 5", "AN 6", "AN 7", "AN 8",
        "SPDIF L", "SPDIF R",
        "ADAT 1", "ADAT 2", "ADAT 3", "ADAT 4", "ADAT 5", "ADAT 6", "ADAT 7", "ADAT 8",
    ]

    /// 18 路软件回放 / 硬件输出单声道默认标签 (`0..17`)：
    /// `0..5`: `AN 1..6`, `6..7`: `PH 7..8`, `8..9`: `SPDIF L/R`, `10..17`: `ADAT 1..8`
    public static let outputMonoLabels: [String] = [
        "AN 1", "AN 2", "AN 3", "AN 4", "AN 5", "AN 6",
        "PH 7", "PH 8",
        "SPDIF L", "SPDIF R",
        "ADAT 1", "ADAT 2", "ADAT 3", "ADAT 4", "ADAT 5", "ADAT 6", "ADAT 7", "ADAT 8",
    ]

    /// 9 对硬件输入立体声合并默认标签（以偶数左通道索引访问）。
    private static let inputStereoLabelsByEvenIndex: [Int: String] = [
        0: "AN 1/2",
        2: "AN 3/4",
        4: "AN 5/6",
        6: "AN 7/8",
        8: "SPDIF L/R",
        10: "ADAT 1/2",
        12: "ADAT 3/4",
        14: "ADAT 5/6",
        16: "ADAT 7/8",
    ]

    /// 9 对软件回放 / 硬件输出立体声合并默认标签（以偶数左通道索引访问）。
    private static let outputStereoLabelsByEvenIndex: [Int: String] = [
        0: "AN 1/2",
        2: "AN 3/4",
        4: "AN 5/6",
        6: "PH 7/8",
        8: "SPDIF L/R",
        10: "ADAT 1/2",
        12: "ADAT 3/4",
        14: "ADAT 5/6",
        16: "ADAT 7/8",
    ]

    /// 返回指定总线与 0-based 通道的单声道兜底名称。
    public static func monoDefaultLabel(bus: MixerBus, index: Int) -> String {
        switch bus {
        case .input:
            if inputMonoLabels.indices.contains(index) {
                return inputMonoLabels[index]
            }
            return "Input \(index + 1)"
        case .playback:
            if outputMonoLabels.indices.contains(index) {
                return outputMonoLabels[index]
            }
            return "Playback \(index + 1)"
        case .output:
            if outputMonoLabels.indices.contains(index) {
                return outputMonoLabels[index]
            }
            return "Output \(index + 1)"
        }
    }

    /// 返回指定总线与偶数左通道索引 `2k` 的立体声合并默认名称。
    public static func stereoDefaultLabel(bus: MixerBus, evenIndex: Int) -> String {
        let baseEven = evenIndex - (evenIndex % 2)
        switch bus {
        case .input:
            if let label = inputStereoLabelsByEvenIndex[baseEven] {
                return label
            }
            return "Input \(baseEven + 1)/\(baseEven + 2)"
        case .playback:
            if let label = outputStereoLabelsByEvenIndex[baseEven] {
                return label
            }
            return "Playback \(baseEven + 1)/\(baseEven + 2)"
        case .output:
            if let label = outputStereoLabelsByEvenIndex[baseEven] {
                return label
            }
            return "Output \(baseEven + 1)/\(baseEven + 2)"
        }
    }

    /// 根据原始上报名称与立体声状态解析最终 UI 展示名：
    /// - 当偶数通道 `2k` 的 `isStereo == true` 时，若 `rawName` 为空或等于单声道默认名（如 `"AN 1"`、`"PH 7"`、`"SPDIF L"`），
    ///   自动合并展示为 `"AN 1/2"`、`"PH 7/8"`、`"SPDIF L/R"` 等；若用户自定义了名称（如 `"Monitors"`）则保留用户名称。
    /// - 当单声道状态且 `rawName` 为空时，回退至单声道默认名。
    public static func resolveDisplayName(
        bus: MixerBus,
        index: Int,
        rawName: String,
        isStereo: Bool
    ) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let monoLabel = monoDefaultLabel(bus: bus, index: index)

        if isStereo && index % 2 == 0 {
            let genericPrefix: String = switch bus {
            case .input: "Input"
            case .playback: "Playback"
            case .output: "Output"
            }
            let genericMono = "\(genericPrefix) \(index + 1)"
            if trimmed.isEmpty
                || trimmed.caseInsensitiveCompare(monoLabel) == .orderedSame
                || trimmed.caseInsensitiveCompare(genericMono) == .orderedSame
            {
                return stereoDefaultLabel(bus: bus, evenIndex: index)
            }
            return trimmed
        }

        if trimmed.isEmpty {
            return monoLabel
        }
        return trimmed
    }

    /// 生成指定总线的 18 路 Fireface UCX 初始通道表。
    ///
    /// 默认 `defaultStereo = true`（9 对立体声通道：偶数 `2k` 为立体声主控槽，奇数 `2k+1` 标记 `isHiddenPartner = true`）。
    public static func defaultChannels(for bus: MixerBus, defaultStereo: Bool = true) -> [MixerChannelState] {
        (0..<channelCount).map { index in
            let isEven = (index % 2 == 0)
            let isStereo = defaultStereo && isEven
            let isHiddenPartner = defaultStereo && !isEven
            let displayName = resolveDisplayName(
                bus: bus,
                index: index,
                rawName: "",
                isStereo: isStereo
            )
            return MixerChannelState(
                index: index,
                bus: bus,
                rawName: "",
                displayName: displayName,
                isStereo: isStereo,
                isHiddenPartner: isHiddenPartner,
                color: 1,
                normalizedFader: 0.0,
                dbValue: RMEFaderCurve.minDb,
                formattedDb: "-∞ dB",
                isMuted: false,
                hasConfirmedValue: false
            )
        }
    }

    /// 将任意通道索引归并为合法控制通道索引：
    /// 若传入奇数右声道 `2k+1` 且其左声道 `2k` 为立体声合并态，自动归并至偶数通道 `2k`（TotalMix 静默丢弃奇数立体声写入）。
    public static func canonicalControlIndex(_ index: Int, in channels: [MixerChannelState]) -> Int {
        guard index >= 0 else { return 0 }
        if index % 2 == 1 {
            let evenPartner = index - 1
            if channels.indices.contains(evenPartner), channels[evenPartner].isStereo {
                return evenPartner
            }
        }
        return index
    }
}
