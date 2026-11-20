import Foundation

/// TourBox Lite 串口底层协议常量、单字节解码与抗分片状态机。
public enum TourBoxProtocol {
    /// 支持的 TourBox USB CDC-ACM 设备 `(vendorID, productID)` 匹配表。
    /// - `0xCAFE:0x4001`：TourBox Lite 实测 VID/PID
    /// - `0x2E3C:0x5740`：雅特力方案批次兼容兜底
    /// - `0xC251:0x2005`：Keil / TourBox 早期/通用 USB 方案兼容兜底
    public static let supportedDevices: [(vendorID: Int, productID: Int)] = [
        (0xCAFE, 0x4001),
        (0x2E3C, 0x5740),
        (0xC251, 0x2005)
    ]

    /// 标准串口波特率（115200 8N1）
    public static let baudRate: Int = 115_200

    /// 8 字节应用层解锁握手命令：`55 00 07 88 94 00 1A FE`
    public static let unlockCommand: [UInt8] = [
        0x55, 0x00, 0x07, 0x88, 0x94, 0x00, 0x1A, 0xFE
    ]

    /// 94 字节初始化激活配置帧（全部震动位关闭 `0x00`，与 `haptic.py` `_CONFIG_MESSAGE_TEMPLATE` 逐字节严格一致）。
    public static let initConfigCommand: [UInt8] = [
        // Config 1 (20 bytes): b5 00 5d 04 + 00 05 .. 00 0d (注：0x09 后直接跳 0x0b)
        0xB5, 0x00, 0x5D, 0x04,
        0x00, 0x05, 0x00, 0x06, 0x00, 0x07, 0x00, 0x08, 0x00, 0x09, 0x00, 0x0B, 0x00, 0x0C, 0x00, 0x0D,
        // Config 2 (20 bytes): 00 0e .. 00 3e
        0x00, 0x0E, 0x00, 0x0F, 0x00, 0x26, 0x00, 0x27, 0x00, 0x28, 0x00, 0x29, 0x00, 0x3B, 0x00, 0x3C, 0x00, 0x3D, 0x00, 0x3E,
        // Config 3 (20 bytes): 00 3f .. 00 48
        0x00, 0x3F, 0x00, 0x40, 0x00, 0x41, 0x00, 0x42, 0x00, 0x43, 0x00, 0x44, 0x00, 0x45, 0x00, 0x46, 0x00, 0x47, 0x00, 0x48,
        // Config 4 (20 bytes): 00 49 .. 00 52
        0x00, 0x49, 0x00, 0x4A, 0x00, 0x4B, 0x00, 0x4C, 0x00, 0x4D, 0x00, 0x4E, 0x00, 0x4F, 0x00, 0x50, 0x00, 0x51, 0x00, 0x52,
        // Config 5 (14 bytes): 00 53 .. 00 ab 00 fe
        0x00, 0x53, 0x00, 0x54, 0x00, 0xA8, 0x00, 0xA9, 0x00, 0xAA, 0x00, 0xAB, 0x00, 0xFE
    ]

    /// 未解锁状态下收到配置帧时固件返回的 20B 拒绝提示串 `<!not_allow_config!>`
    public static let notAllowConfigBanner: [UInt8] = Array("<!not_allow_config!>".utf8)

    /// 固件标准解锁响应帧长度（26 字节，如 TourBox Lite 以 `0x04` 开头、Elite 以 `0x07` 开头，尾部含 `00 ... 00 00`；握手仅按长度 + 静默窗判定，不绑死首字节）
    public static let unlockExpectedResponseBytes: Int = 26

    /// 解锁响应收满 26B 后的静默确认窗（15 ms 无新字节视为响应帧完整收齐）
    public static let unlockQuiescenceInterval: TimeInterval = 0.015

    /// 解锁响应最大等待超时兜底（300 ms，兼容热重启时固件已处于解锁态不回包的场景）
    public static let unlockTimeoutInterval: TimeInterval = 0.300

    /// 写入 94B 激活配置帧后的强制排空屏障（50 ms，吞掉一切残余响应后才进入 `.streaming`）
    public static let configDrainInterval: TimeInterval = 0.050

    /// 运行态检测到非法字节或突发长包（`>= 8B`）时的污染隔离窗（40 ms，拦截分片尾包末尾 `0x00` 串）
    public static let quarantineInterval: TimeInterval = 0.040

    /// 运行态单次 `read` 视为设备响应帧而非人工按键的单批字节数阈值
    public static let streamingBurstThreshold: Int = 8

    /// 最大解锁尝试次数（首次 + 遇 `<!not_allow_config!>` 重试 1 次）
    public static let maxUnlockAttempts: Int = 2

    /// 检查给定 USB 属性是否匹配受支持的 TourBox 设备。
    public static func isSupportedDevice(
        vendorID: Int?,
        productID: Int?,
        vendorName: String? = nil,
        productName: String? = nil
    ) -> Bool {
        if let vid = vendorID, let pid = productID {
            if supportedDevices.contains(where: { $0.vendorID == vid && $0.productID == pid }) {
                return true
            }
        }
        if let vendorName, vendorName.localizedCaseInsensitiveContains("TourBox") {
            return true
        }
        if let productName, productName.localizedCaseInsensitiveContains("TourBox") {
            return true
        }
        return false
    }

    /// 按 TourBox Lite 白名单解码单个字节。
    public static func decode(_ byte: UInt8) -> TourBoxDecodedByte? {
        TourBoxDecodedByte.decode(byte)
    }

    /// 将字节序列格式化为大写十六进制字符串（空格分隔）。
    public static func hexString(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

/// 纯逻辑、零 I/O 可确定性单元测试的 TourBox 四阶段握手与运行态 `40 ms` 污染隔离过滤器。
///
/// 状态迁移路径：
/// `.disconnected` -> `.handshakingUnlock` (26B + 15ms 静默窗 / `<!not_allow_config!>` 重试 / 300ms 超时兜底)
/// -> `.handshakingConfig` (发送 94B 激活帧 + 50ms 排空屏障)
/// -> `.streaming` (严格校验白名单 + 突发帧/非法字节触发 `40 ms` Quarantine 隔离并置 `resetStateMachine = true`)
public struct TourBoxStreamFilter: Sendable {
    public enum Phase: String, Equatable, Sendable {
        case disconnected
        case handshakingUnlock
        case handshakingConfig
        case streaming
    }

    public struct DecodedSample: Equatable, Sendable {
        public let decoded: TourBoxDecodedByte
        public let rawByte: UInt8
        public let timestamp: TimeInterval

        public init(decoded: TourBoxDecodedByte, rawByte: UInt8, timestamp: TimeInterval) {
            self.decoded = decoded
            self.rawByte = rawByte
            self.timestamp = timestamp
        }
    }

    public struct DiagnosticEntry: Equatable, Sendable {
        public let direction: String
        public let hex: String
        public let note: String

        public init(direction: String, hex: String, note: String) {
            self.direction = direction
            self.hex = hex
            self.note = note
        }
    }

    public struct FilterResult: Equatable, Sendable {
        /// 需要立即按序写入串口的完整指令帧（如 8B 解锁帧或 94B 激活帧）
        public var commandsToWrite: [[UInt8]]
        /// 在 `.streaming` 非隔离态下解码出的合法单字节事件
        public var inputs: [DecodedSample]
        /// 通知上层立即执行 `ControlStateMachine.reset()`（配置排空完成、40ms 隔离结束或断开时置 `true`）
        public var resetStateMachine: Bool
        /// 本次调用是否刚刚完成握手并正式进入 `.streaming` 已连接态
        public var didEnterStreaming: Bool
        /// 本次调用是否刚刚触发了运行态 `40 ms` Quarantine 隔离窗
        public var enteredQuarantine: Bool
        /// 供诊断视图消费的原始报文与状态说明
        public var diagnostics: [DiagnosticEntry]

        /// 剔除 `.rotaryStop` 后的实际有效动作输入（`.rotaryStop` 计 0 步）
        public var actionableInputs: [DecodedSample] {
            inputs.filter { !$0.decoded.isRotaryStop }
        }

        public init(
            commandsToWrite: [[UInt8]] = [],
            inputs: [DecodedSample] = [],
            resetStateMachine: Bool = false,
            didEnterStreaming: Bool = false,
            enteredQuarantine: Bool = false,
            diagnostics: [DiagnosticEntry] = []
        ) {
            self.commandsToWrite = commandsToWrite
            self.inputs = inputs
            self.resetStateMachine = resetStateMachine
            self.didEnterStreaming = didEnterStreaming
            self.enteredQuarantine = enteredQuarantine
            self.diagnostics = diagnostics
        }

        mutating func merge(_ other: FilterResult) {
            commandsToWrite.append(contentsOf: other.commandsToWrite)
            inputs.append(contentsOf: other.inputs)
            resetStateMachine = resetStateMachine || other.resetStateMachine
            didEnterStreaming = didEnterStreaming || other.didEnterStreaming
            enteredQuarantine = enteredQuarantine || other.enteredQuarantine
            diagnostics.append(contentsOf: other.diagnostics)
        }
    }

    private static let timeEpsilon: TimeInterval = 1e-6

    public private(set) var phase: Phase = .disconnected
    public private(set) var handshakeBuffer: [UInt8] = []
    public private(set) var unlockAttempts: Int = 0
    public private(set) var quarantineUntil: TimeInterval?

    private var unlockStartedAt: TimeInterval?
    private var lastUnlockByteAt: TimeInterval?
    private var configDrainUntil: TimeInterval?
    private var configDrainBuffer: [UInt8] = []

    public init() {}

    /// 当前是否处于 `.streaming` 运行态 `40 ms` 污染隔离窗内
    public var isQuarantined: Bool {
        quarantineUntil != nil
    }

    /// 供外部串行定时器调度的最近一个待触发截止时刻（`nil` 表示当前无需定时器唤醒）
    public var nextDeadline: TimeInterval? {
        switch phase {
        case .disconnected:
            return nil
        case .handshakingUnlock:
            guard let startedAt = unlockStartedAt else { return nil }
            let timeoutAt = startedAt + TourBoxProtocol.unlockTimeoutInterval
            if handshakeBuffer.count >= TourBoxProtocol.unlockExpectedResponseBytes,
               let lastByteAt = lastUnlockByteAt {
                let quiescenceAt = lastByteAt + TourBoxProtocol.unlockQuiescenceInterval
                return min(timeoutAt, quiescenceAt)
            }
            return timeoutAt
        case .handshakingConfig:
            return configDrainUntil
        case .streaming:
            return quarantineUntil
        }
    }

    /// 启动第一阶段解锁握手（下发 8B `unlockCommand`）。
    public mutating func beginHandshake(now: TimeInterval) -> FilterResult {
        phase = .handshakingUnlock
        handshakeBuffer.removeAll(keepingCapacity: true)
        configDrainBuffer.removeAll(keepingCapacity: true)
        unlockStartedAt = now
        lastUnlockByteAt = nil
        configDrainUntil = nil
        quarantineUntil = nil
        unlockAttempts = 1

        return FilterResult(
            commandsToWrite: [TourBoxProtocol.unlockCommand],
            diagnostics: [
                DiagnosticEntry(
                    direction: "TX",
                    hex: TourBoxProtocol.hexString(TourBoxProtocol.unlockCommand),
                    note: "发送 8B 解锁握手帧 (尝试 #1)"
                )
            ]
        )
    }

    /// 重置连接为 `.disconnected`，并在需要时标记重置上层按键状态机。
    public mutating func reset() -> FilterResult {
        let shouldReset = phase != .disconnected || quarantineUntil != nil
        phase = .disconnected
        handshakeBuffer.removeAll(keepingCapacity: false)
        configDrainBuffer.removeAll(keepingCapacity: false)
        unlockStartedAt = nil
        lastUnlockByteAt = nil
        configDrainUntil = nil
        quarantineUntil = nil
        unlockAttempts = 0
        return FilterResult(resetStateMachine: shouldReset)
    }

    /// 推进时钟以结算已到期的静默窗、超时兜底、配置排空屏障或 `40 ms` 隔离窗。
    public mutating func advanceTime(now: TimeInterval) -> FilterResult {
        var result = FilterResult()

        switch phase {
        case .disconnected:
            break

        case .handshakingUnlock:
            guard let startedAt = unlockStartedAt else { break }
            let quiescenceReady: Bool = {
                guard handshakeBuffer.count >= TourBoxProtocol.unlockExpectedResponseBytes,
                      let lastByteAt = lastUnlockByteAt else {
                    return false
                }
                return now + Self.timeEpsilon >= lastByteAt + TourBoxProtocol.unlockQuiescenceInterval
            }()
            let timedOut = now + Self.timeEpsilon >= startedAt + TourBoxProtocol.unlockTimeoutInterval

            if quiescenceReady || timedOut {
                let note: String
                let rxHex = TourBoxProtocol.hexString(handshakeBuffer)
                if quiescenceReady {
                    note = "解锁响应已收齐 (\(handshakeBuffer.count)B + 15ms 静默确认)，发送 94B 激活配置帧"
                } else {
                    note = "解锁等待满 300ms 超时兜底 (已收 \(handshakeBuffer.count)B)，发送 94B 激活配置帧"
                }
                if !handshakeBuffer.isEmpty {
                    result.diagnostics.append(
                        DiagnosticEntry(direction: "RX", hex: rxHex, note: "消费握手响应缓冲 (\(handshakeBuffer.count)B)")
                    )
                }
                transitionToConfigPhase(now: now, note: note, into: &result)
            }

        case .handshakingConfig:
            if let drainUntil = configDrainUntil, now + Self.timeEpsilon >= drainUntil {
                if !configDrainBuffer.isEmpty {
                    result.diagnostics.append(
                        DiagnosticEntry(
                            direction: "RX",
                            hex: TourBoxProtocol.hexString(configDrainBuffer),
                            note: "50ms 配置排空屏障吞掉残余字节 (\(configDrainBuffer.count)B)"
                        )
                    )
                }
                configDrainBuffer.removeAll(keepingCapacity: false)
                configDrainUntil = nil
                phase = .streaming
                result.resetStateMachine = true
                result.didEnterStreaming = true
                result.diagnostics.append(
                    DiagnosticEntry(direction: "SYS", hex: "", note: "握手与排空完成，进入 .streaming 实时事件流")
                )
            }

        case .streaming:
            if let until = quarantineUntil, now + Self.timeEpsilon >= until {
                quarantineUntil = nil
                result.resetStateMachine = true
                result.diagnostics.append(
                    DiagnosticEntry(direction: "SYS", hex: "", note: "40ms 污染隔离窗结束，重置按键状态机恢复正常接收")
                )
            }
        }

        return result
    }

    /// 喂入一次底层非阻塞 `read` 读到的字节分片。
    public mutating func ingest(_ chunk: [UInt8], now: TimeInterval) -> FilterResult {
        var result = advanceTime(now: now)
        guard !chunk.isEmpty else { return result }

        switch phase {
        case .disconnected:
            // 未启动握手前到达的残余噪声直接丢弃
            result.diagnostics.append(
                DiagnosticEntry(
                    direction: "RX",
                    hex: TourBoxProtocol.hexString(chunk),
                    note: "忽略未连接态残余字节 (\(chunk.count)B)"
                )
            )

        case .handshakingUnlock:
            handshakeBuffer.append(contentsOf: chunk)
            lastUnlockByteAt = now

            if containsSubsequence(handshakeBuffer, pattern: TourBoxProtocol.notAllowConfigBanner) {
                let rawHex = TourBoxProtocol.hexString(handshakeBuffer)
                handshakeBuffer.removeAll(keepingCapacity: true)
                lastUnlockByteAt = nil
                if unlockAttempts < TourBoxProtocol.maxUnlockAttempts {
                    unlockAttempts += 1
                    unlockStartedAt = now
                    result.commandsToWrite.append(TourBoxProtocol.unlockCommand)
                    result.diagnostics.append(
                        DiagnosticEntry(
                            direction: "RX",
                            hex: rawHex,
                            note: "收到 <!not_allow_config!>，重发 8B 解锁帧 (尝试 #\(unlockAttempts))"
                        )
                    )
                } else {
                    transitionToConfigPhase(
                        now: now,
                        note: "重试解锁后仍收到 <!not_allow_config!>，尝试兜底发送 94B 配置帧",
                        into: &result
                    )
                }
            }

        case .handshakingConfig:
            configDrainBuffer.append(contentsOf: chunk)
            if containsSubsequence(configDrainBuffer, pattern: TourBoxProtocol.notAllowConfigBanner),
               unlockAttempts < TourBoxProtocol.maxUnlockAttempts {
                let rawHex = TourBoxProtocol.hexString(configDrainBuffer)
                configDrainBuffer.removeAll(keepingCapacity: true)
                configDrainUntil = nil
                phase = .handshakingUnlock
                handshakeBuffer.removeAll(keepingCapacity: true)
                unlockAttempts += 1
                unlockStartedAt = now
                lastUnlockByteAt = nil
                result.commandsToWrite.append(TourBoxProtocol.unlockCommand)
                result.diagnostics.append(
                    DiagnosticEntry(
                        direction: "RX",
                        hex: rawHex,
                        note: "配置阶段收到 <!not_allow_config!>，回退重发 8B 解锁帧 (尝试 #\(unlockAttempts))"
                    )
                )
            }

        case .streaming:
            let hasIllegalByte = !chunk.allSatisfy { TourBoxDecodedByte.validSingleBytes.contains($0) }
            let isBurstFrame = chunk.count >= TourBoxProtocol.streamingBurstThreshold

            if let activeUntil = quarantineUntil {
                // 已在 40ms 隔离窗内：无条件吞掉分片尾包（拦截响应帧末尾 00 03 02 02 00 00）
                if hasIllegalByte || isBurstFrame {
                    quarantineUntil = max(activeUntil, now + TourBoxProtocol.quarantineInterval)
                }
                result.diagnostics.append(
                    DiagnosticEntry(
                        direction: "RX",
                        hex: TourBoxProtocol.hexString(chunk),
                        note: "40ms 隔离窗内丢弃分片尾包 (\(chunk.count)B)"
                    )
                )
                return result
            }

            if hasIllegalByte || isBurstFrame {
                quarantineUntil = now + TourBoxProtocol.quarantineInterval
                result.enteredQuarantine = true
                let reason = isBurstFrame
                    ? "检测到突发长帧 (\(chunk.count)B >= \(TourBoxProtocol.streamingBurstThreshold)B)"
                    : "检测到非白名单污染字节"
                result.diagnostics.append(
                    DiagnosticEntry(
                        direction: "RX",
                        hex: TourBoxProtocol.hexString(chunk),
                        note: "\(reason)，开启 40ms Quarantine 污染隔离窗并丢弃当前批次"
                    )
                )
                return result
            }

            for byte in chunk {
                if let decoded = TourBoxProtocol.decode(byte) {
                    result.inputs.append(
                        DecodedSample(decoded: decoded, rawByte: byte, timestamp: now)
                    )
                }
            }
        }

        return result
    }

    private mutating func transitionToConfigPhase(
        now: TimeInterval,
        note: String,
        into result: inout FilterResult
    ) {
        handshakeBuffer.removeAll(keepingCapacity: false)
        lastUnlockByteAt = nil
        unlockStartedAt = nil
        phase = .handshakingConfig
        configDrainBuffer.removeAll(keepingCapacity: true)
        configDrainUntil = now + TourBoxProtocol.configDrainInterval

        result.commandsToWrite.append(TourBoxProtocol.initConfigCommand)
        result.diagnostics.append(
            DiagnosticEntry(
                direction: "TX",
                hex: "\(TourBoxProtocol.hexString(TourBoxProtocol.initConfigCommand.prefix(8))) … (\(TourBoxProtocol.initConfigCommand.count)B)",
                note: note
            )
        )
    }

    private func containsSubsequence(_ haystack: [UInt8], pattern: [UInt8]) -> Bool {
        guard !pattern.isEmpty, haystack.count >= pattern.count else { return false }
        let limit = haystack.count - pattern.count
        for start in 0...limit {
            if haystack[start..<(start + pattern.count)].elementsEqual(pattern) {
                return true
            }
        }
        return false
    }
}
