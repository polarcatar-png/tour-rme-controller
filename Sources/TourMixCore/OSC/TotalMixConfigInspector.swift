import Foundation

/// TotalMix FX `OSCCompatibility` 模式枚举（经 TotalMixFX v2.10 二进制与 NIB 核实）。
public enum TotalMixOSCCompatibilityMode: Int, Equatable, Sendable {
    /// TotalMix 1.90 旧版分页协议
    case legacy190 = 0
    /// TotalMix 1.96 扩展分页协议
    case legacy196 = 1
    /// TotalMix 2.10+ 无状态绝对寻址 `Global OSC`
    case globalOSC = 2
    /// 未知未来版本枚举值
    case unknown = -1

    public init(rawInt: Int) {
        switch rawInt {
        case 0: self = .legacy190
        case 1: self = .legacy196
        case 2: self = .globalOSC
        default: self = .unknown
        }
    }

    public var displayName: String {
        switch self {
        case .legacy190: return "TotalMix 1.90"
        case .legacy196: return "TotalMix 1.96"
        case .globalOSC: return "Global OSC"
        case .unknown: return "Unknown"
        }
    }
}

/// 单个 `<OscRemote0>..<OscRemote3>` 远程控制器槽位的快照配置。
public struct OscRemoteSlotConfig: Equatable, Sendable {
    /// 槽位索引 `0...3`（对应 UI 的 Remote Controller 1...4）。
    public var slotIndex: Int
    /// `In Use` 勾选状态（对应 `OSCRemoteInUse == 1`）。
    public var inUse: Bool
    /// TotalMix 自身监听端口（`OSCOwnPort`，默认 `7001`）。
    public var ownPort: Int
    /// TotalMix 发送目标端口（`OSCRemotePort`，默认 `9001`）。
    public var remotePort: Int
    /// 远程控制器主机地址（`OSCRemoteHost`，本机应填 `"127.0.0.1"`）。
    public var remoteHost: String
    /// 兼容模式原始整数（`2 == Global OSC`）。
    public var compatibilityRaw: Int
    /// `Details...` 位掩码（`GlobalOSCSettings`，默认 `0` 表示 `Send changes` 开启）。
    public var globalOSCSettings: Int

    public var compatibility: TotalMixOSCCompatibilityMode {
        TotalMixOSCCompatibilityMode(rawInt: compatibilityRaw)
    }

    /// `GlobalOSCSettings` Bit 0 为 `0` 表示开启了 `Send changes`。
    public var sendChangesEnabled: Bool {
        (globalOSCSettings & 0x01) == 0
    }

    /// `GlobalOSCSettings` Bit 2 (`0x04`) 表示开启 `Receive to hidden channels`。
    public var receiveToHiddenChannelsEnabled: Bool {
        (globalOSCSettings & 0x04) != 0
    }

    /// `GlobalOSCSettings` Bit 8 (`0x0100`) 表示开启 `Re-send received`。
    public var resendReceivedEnabled: Bool {
        (globalOSCSettings & 0x0100) != 0
    }

    public init(
        slotIndex: Int,
        inUse: Bool = false,
        ownPort: Int = 7001,
        remotePort: Int = 9001,
        remoteHost: String = "",
        compatibilityRaw: Int = 0,
        globalOSCSettings: Int = 0
    ) {
        self.slotIndex = slotIndex
        self.inUse = inUse
        self.ownPort = ownPort
        self.remotePort = remotePort
        self.remoteHost = remoteHost
        self.compatibilityRaw = compatibilityRaw
        self.globalOSCSettings = globalOSCSettings
    }
}

/// 离线 XML 快照检测出的具体配置差异项。
public enum TotalMixConfigIssue: Equatable, Sendable {
    case configDirectoryNotFound
    case xmlFileNotFound
    case oscMasterDisabled
    case remoteSlotNotInUse(slotNumber: Int)
    case compatibilityNotGlobalOSC(slotNumber: Int, current: TotalMixOSCCompatibilityMode)
    case remoteHostEmptyOrNonLocal(slotNumber: Int, currentHost: String)
    case portMismatch(slotNumber: Int, ownPort: Int, remotePort: Int, expectedOwnPort: Int, expectedRemotePort: Int)
    case sendChangesDisabled(slotNumber: Int)
}

/// TotalMix FX 离线磁盘 XML 快照诊断结果。
///
/// ⚠️ 重要架构原则：
/// TotalMix 默认 `SaveOnChanges = 0`，运行期间修改 OSC 设置**不会立即刷盘写 XML**（仅在退出 TotalMix 时保存）。
/// 因此本诊断结果**仅用于 UDP 握手超时（`> 1.2s` 无响应）时的离线辅助提示**，绝不能否定实时 UDP 在线状态。
public struct TotalMixConfigDiagnostic: Equatable, Sendable {
    public let xmlFileURL: URL?
    public let lastModifiedDate: Date?
    public let deviceName: String?
    /// `<General>` 中的 `OSCEnabled == 1`（对应菜单 `Options -> Enable OSC Control`）。
    public let oscMasterEnabled: Bool
    /// `<General>` 中的 `MainChannel`（0-based 输出通道索引，例如 `6` 对应 `PH 7/8`）。
    public let mainChannelIndex: Int?
    /// `MainChannel` 对应的可读立体声名称（例如 `"PH 7/8"` 或 `"AN 1/2"`）。
    public let mainChannelDisplayName: String?
    /// `<OscRemote0>..<OscRemote3>` 共 4 个槽位快照。
    public let remotes: [OscRemoteSlotConfig]
    /// 匹配目标端口或最佳候选的远程槽位。
    public let matchedRemote: OscRemoteSlotConfig?
    /// 检测到的离线快照差异项。
    public let issues: [TotalMixConfigIssue]
    /// 面向 UI 展示的简明中文诊断提示（明确告知无需重启 TotalMix 自动秒连）。
    public let offlineHintSummary: String

    /// 快照中是否已完整开启 Global OSC 并匹配端口。
    public var isSnapshotConfiguredForGlobalOSC: Bool {
        issues.isEmpty && !remotes.isEmpty
    }

    public init(
        xmlFileURL: URL?,
        lastModifiedDate: Date?,
        deviceName: String?,
        oscMasterEnabled: Bool,
        mainChannelIndex: Int?,
        mainChannelDisplayName: String?,
        remotes: [OscRemoteSlotConfig],
        matchedRemote: OscRemoteSlotConfig?,
        issues: [TotalMixConfigIssue],
        offlineHintSummary: String
    ) {
        self.xmlFileURL = xmlFileURL
        self.lastModifiedDate = lastModifiedDate
        self.deviceName = deviceName
        self.oscMasterEnabled = oscMasterEnabled
        self.mainChannelIndex = mainChannelIndex
        self.mainChannelDisplayName = mainChannelDisplayName
        self.remotes = remotes
        self.matchedRemote = matchedRemote
        self.issues = issues
        self.offlineHintSummary = offlineHintSummary
    }
}

/// RME TotalMix FX 磁盘 XML 配置只读自检器。
public enum TotalMixConfigInspector: Sendable {
    /// 默认配置目录：`~/Library/Application Support/RME TotalMix FX`
    public static var defaultDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("RME TotalMix FX", isDirectory: true)
    }

    /// 扫描指定目录（默认 `~/Library/Application Support/RME TotalMix FX/`）下修改时间最新的 `last.FirefaceUCX*.xml`，
    /// 生成离线辅助诊断结果。
    public static func inspect(
        directoryURL: URL? = nil,
        expectedOutgoingPort: UInt16 = 7001,
        expectedIncomingPort: UInt16 = 9001
    ) -> TotalMixConfigDiagnostic {
        let dir = directoryURL ?? defaultDirectoryURL
        let fm = FileManager.default

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return TotalMixConfigDiagnostic(
                xmlFileURL: nil,
                lastModifiedDate: nil,
                deviceName: nil,
                oscMasterEnabled: false,
                mainChannelIndex: nil,
                mainChannelDisplayName: nil,
                remotes: [],
                matchedRemote: nil,
                issues: [.configDirectoryNotFound],
                offlineHintSummary: "未收到 TotalMix OSC 响应（未找到 RME TotalMix FX 配置目录；请启动 TotalMix FX 并开启 Global OSC，无需重启将自动秒连）。"
            )
        }

        guard let newest = findNewestDeviceStateXML(in: dir) else {
            return TotalMixConfigDiagnostic(
                xmlFileURL: nil,
                lastModifiedDate: nil,
                deviceName: nil,
                oscMasterEnabled: false,
                mainChannelIndex: nil,
                mainChannelDisplayName: nil,
                remotes: [],
                matchedRemote: nil,
                issues: [.xmlFileNotFound],
                offlineHintSummary: "未收到 TotalMix OSC 响应（未找到 Fireface UCX 配置快照；请在 TotalMix 开启 Global OSC，无需重启将自动秒连）。"
            )
        }

        guard let rawData = try? Data(contentsOf: newest.url) else {
            return TotalMixConfigDiagnostic(
                xmlFileURL: newest.url,
                lastModifiedDate: newest.modifiedAt,
                deviceName: nil,
                oscMasterEnabled: false,
                mainChannelIndex: nil,
                mainChannelDisplayName: nil,
                remotes: [],
                matchedRemote: nil,
                issues: [.xmlFileNotFound],
                offlineHintSummary: "未收到 TotalMix OSC 响应（无法读取磁盘配置快照；在 TotalMix 开启 Global OSC 后无需重启将自动秒连）。"
            )
        }

        return parseXMLData(
            rawData,
            xmlFileURL: newest.url,
            lastModifiedDate: newest.modifiedAt,
            expectedOutgoingPort: expectedOutgoingPort,
            expectedIncomingPort: expectedIncomingPort
        )
    }

    /// 直接解析 TotalMix XML 字节数据（支持单元测试注入无 `<?xml?>` 头、多根节点 `<FirefaceUCX...><Frame0>` 及 `"6.00,..."` 属性）。
    public static func parseXMLData(
        _ data: Data,
        xmlFileURL: URL? = nil,
        lastModifiedDate: Date? = nil,
        expectedOutgoingPort: UInt16 = 7001,
        expectedIncomingPort: UInt16 = 9001
    ) -> TotalMixConfigDiagnostic {
        let rawText = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""

        let strippedText = stripXMLDeclarationIfPresent(rawText)
        let wrappedXML = "<TourMixSyntheticRoot>\n\(strippedText)\n</TourMixSyntheticRoot>"
        let wrappedData = Data(wrappedXML.utf8)

        let delegate = TotalMixXMLDelegate()
        let parser = XMLParser(data: wrappedData)
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        _ = parser.parse()

        let remotes = (0..<4).map { idx in
            delegate.slots[idx] ?? OscRemoteSlotConfig(
                slotIndex: idx,
                inUse: false,
                ownPort: 7001 + idx,
                remotePort: 9001 + idx,
                remoteHost: "",
                compatibilityRaw: 0,
                globalOSCSettings: 0
            )
        }

        let targetOwnPort = Int(expectedOutgoingPort)
        let targetRemotePort = Int(expectedIncomingPort)

        // 优先匹配 OSCOwnPort == expectedOutgoingPort 的槽位，否则优先已启用的 Global OSC 槽位，最后回退槽位 0
        let matched = remotes.first(where: { $0.ownPort == targetOwnPort && $0.inUse })
            ?? remotes.first(where: { $0.ownPort == targetOwnPort })
            ?? remotes.first(where: { $0.inUse && $0.compatibility == .globalOSC })
            ?? remotes.first

        var issues: [TotalMixConfigIssue] = []
        if !delegate.oscMasterEnabled {
            issues.append(.oscMasterDisabled)
        }

        if let slot = matched {
            let humanSlot = slot.slotIndex + 1
            if !slot.inUse {
                issues.append(.remoteSlotNotInUse(slotNumber: humanSlot))
            }
            if slot.compatibility != .globalOSC {
                issues.append(.compatibilityNotGlobalOSC(slotNumber: humanSlot, current: slot.compatibility))
            }
            let hostTrimmed = slot.remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
            let isLocalHost = hostTrimmed == "127.0.0.1"
                || hostTrimmed.caseInsensitiveCompare("localhost") == .orderedSame
            if !isLocalHost {
                issues.append(.remoteHostEmptyOrNonLocal(slotNumber: humanSlot, currentHost: hostTrimmed))
            }
            if slot.ownPort != targetOwnPort || slot.remotePort != targetRemotePort {
                issues.append(
                    .portMismatch(
                        slotNumber: humanSlot,
                        ownPort: slot.ownPort,
                        remotePort: slot.remotePort,
                        expectedOwnPort: targetOwnPort,
                        expectedRemotePort: targetRemotePort
                    )
                )
            }
            if !slot.sendChangesEnabled {
                issues.append(.sendChangesDisabled(slotNumber: humanSlot))
            }
        }

        let mainChannelIndex = delegate.mainChannelIndex
        let mainDisplay: String? = mainChannelIndex.map { idx in
            FirefaceUCXProfile.stereoDefaultLabel(bus: .output, evenIndex: idx)
        }

        let summary = buildOfflineSummary(
            issues: issues,
            matchedSlot: matched,
            expectedOutgoingPort: expectedOutgoingPort,
            expectedIncomingPort: expectedIncomingPort
        )

        return TotalMixConfigDiagnostic(
            xmlFileURL: xmlFileURL,
            lastModifiedDate: lastModifiedDate,
            deviceName: delegate.deviceName,
            oscMasterEnabled: delegate.oscMasterEnabled,
            mainChannelIndex: mainChannelIndex,
            mainChannelDisplayName: mainDisplay,
            remotes: remotes,
            matchedRemote: matched,
            issues: issues,
            offlineHintSummary: summary
        )
    }

    /// 解析 TotalMix XML 的 `v` 属性首段整数（兼容 `"0"`、`"6.00"` 及 `"6.00,6.00,..."` 多快照列表）。
    public static func parseNumericAttribute(_ raw: String) -> Int? {
        let firstSegment = raw.split(separator: ",", omittingEmptySubsequences: true).first
            ?? Substring(raw)
        let trimmed = firstSegment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let dbl = Double(trimmed), dbl.isFinite else {
            return nil
        }
        return Int(dbl.rounded())
    }

    // MARK: - Helpers

    private static func findNewestDeviceStateXML(in directoryURL: URL) -> (url: URL, modifiedAt: Date)? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var ucxCandidates: [(url: URL, modifiedAt: Date)] = []
        var fallbackCandidates: [(url: URL, modifiedAt: Date)] = []

        for url in urls {
            let name = url.lastPathComponent
            let lower = name.lowercased()
            guard lower.hasSuffix(".xml") else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile != false else { continue }
            let modified = values?.contentModificationDate ?? .distantPast

            if lower.hasPrefix("last.firefaceucx") {
                ucxCandidates.append((url, modified))
            } else if lower.hasPrefix("last.") {
                fallbackCandidates.append((url, modified))
            }
        }

        let pool = ucxCandidates.isEmpty ? fallbackCandidates : ucxCandidates
        return pool.max(by: { $0.modifiedAt < $1.modifiedAt })
    }

    private static func stripXMLDeclarationIfPresent(_ xml: String) -> String {
        let trimmed = xml.drop(while: { $0.isWhitespace })
        guard trimmed.hasPrefix("<?xml") else {
            return xml
        }
        if let closeRange = trimmed.range(of: "?>") {
            return String(trimmed[closeRange.upperBound...])
        }
        return xml
    }

    private static func buildOfflineSummary(
        issues: [TotalMixConfigIssue],
        matchedSlot: OscRemoteSlotConfig?,
        expectedOutgoingPort: UInt16,
        expectedIncomingPort: UInt16
    ) -> String {
        if issues.isEmpty {
            return "未收到 TotalMix OSC 响应（磁盘快照配置正常，请确认 TotalMix FX 正在运行；启动后将自动秒连）。"
        }

        var parts: [String] = []
        for issue in issues {
            switch issue {
            case .oscMasterDisabled:
                parts.append("菜单 Options → Enable OSC Control 尚未勾选")
            case .remoteSlotNotInUse(let slotNumber):
                parts.append("Remote Controller \(slotNumber) 未勾选 In Use")
            case .compatibilityNotGlobalOSC(let slotNumber, let current):
                parts.append("Remote Controller \(slotNumber) 当前为 \(current.displayName)，需切换为 Global OSC")
            case .remoteHostEmptyOrNonLocal(let slotNumber, let host):
                let shown = host.isEmpty ? "空" : host
                parts.append("Remote Controller \(slotNumber) 地址为 \(shown)，需填入 127.0.0.1")
            case .portMismatch(let slotNumber, let own, let rem, let expOwn, let expRem):
                parts.append("Remote Controller \(slotNumber) 端口为 \(own)/\(rem)（当前期望 \(expOwn)/\(expRem)）")
            case .sendChangesDisabled(let slotNumber):
                parts.append("Remote Controller \(slotNumber) Details 中 Send changes 被关闭")
            case .configDirectoryNotFound, .xmlFileNotFound:
                parts.append("未找到本地快照")
            }
        }

        let detail = parts.joined(separator: "；")
        let slotHint = matchedSlot.map { "Remote \($0.slotIndex + 1)" } ?? "OSC"
        return "未收到 TotalMix OSC 响应（磁盘快照显示 \(slotHint)：\(detail)。在 TotalMix 开启 Global OSC 后无需重启将自动秒连）。"
    }
}

// MARK: - Private XMLParserDelegate

private final class TotalMixXMLDelegate: NSObject, XMLParserDelegate {
    var elementStack: [String] = []
    var oscMasterEnabled: Bool = false
    var mainChannelIndex: Int?
    var deviceName: String?
    var slots: [Int: OscRemoteSlotConfig] = [:]

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        elementStack.append(elementName)

        // 若根元素名形如 <FirefaceUCX23908219>，可作为备用设备名参考
        if elementStack.count == 2,
           elementName != "Frame0",
           elementName != "Preferences",
           deviceName == nil
        {
            deviceName = elementName
        }

        guard elementName == "val",
              let key = attributeDict["e"],
              let rawVal = attributeDict["v"]
        else {
            return
        }

        let parent = elementStack.dropLast().last ?? ""

        if parent == "General" {
            switch key {
            case "OSCEnabled":
                oscMasterEnabled = (TotalMixConfigInspector.parseNumericAttribute(rawVal) == 1)
            case "MainChannel":
                if let ch = TotalMixConfigInspector.parseNumericAttribute(rawVal), ch >= 0 {
                    mainChannelIndex = ch
                }
            default:
                break
            }
            return
        }

        if let slotIdx = Self.parseOscRemoteIndex(parent) {
            var slot = slots[slotIdx] ?? OscRemoteSlotConfig(
                slotIndex: slotIdx,
                inUse: false,
                ownPort: 7001 + slotIdx,
                remotePort: 9001 + slotIdx,
                remoteHost: "",
                compatibilityRaw: 0,
                globalOSCSettings: 0
            )
            switch key {
            case "OSCRemoteInUse":
                slot.inUse = (TotalMixConfigInspector.parseNumericAttribute(rawVal) == 1)
            case "OSCEnabled":
                // 兼容部分测试或变体 XML 将 OSCEnabled 写在 OscRemote 节点内
                let enabled = (TotalMixConfigInspector.parseNumericAttribute(rawVal) == 1)
                if enabled {
                    slot.inUse = true
                    oscMasterEnabled = true
                }
            case "OSCOwnPort":
                if let port = TotalMixConfigInspector.parseNumericAttribute(rawVal), port > 0 {
                    slot.ownPort = port
                }
            case "OSCRemotePort":
                if let port = TotalMixConfigInspector.parseNumericAttribute(rawVal), port > 0 {
                    slot.remotePort = port
                }
            case "OSCRemoteHost":
                slot.remoteHost = rawVal.trimmingCharacters(in: .whitespacesAndNewlines)
            case "OSCCompatibility":
                if let mode = TotalMixConfigInspector.parseNumericAttribute(rawVal) {
                    slot.compatibilityRaw = mode
                }
            case "GlobalOSCSettings":
                if let settings = TotalMixConfigInspector.parseNumericAttribute(rawVal) {
                    slot.globalOSCSettings = settings
                }
            default:
                break
            }
            slots[slotIdx] = slot
            return
        }

        if key == "DeviceName", !rawVal.isEmpty {
            deviceName = rawVal
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if !elementStack.isEmpty {
            elementStack.removeLast()
        }
    }

    private static func parseOscRemoteIndex(_ elementName: String) -> Int? {
        guard elementName.hasPrefix("OscRemote") else { return nil }
        let suffix = elementName.dropFirst("OscRemote".count)
        guard let idx = Int(suffix), (0...3).contains(idx) else { return nil }
        return idx
    }
}
