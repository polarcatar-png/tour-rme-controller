import Darwin
import Foundation

/// OSC UDP 传输层端点配置（从 TourMix 视角命名）。
public struct OSCTransportConfiguration: Equatable, Sendable {
    /// 本地绑定监听地址（默认 `"127.0.0.1"`）。
    public var localHost: String
    /// TourMix 本地监听端口（接收 TotalMix 回包，默认 `9001`）。
    public var incomingPort: UInt16
    /// TotalMix 目标主机地址（默认 `"127.0.0.1"`）。
    public var remoteHost: String
    /// TourMix 发送目标端口（对应 TotalMix Incoming Port，默认 `7001`）。
    public var outgoingPort: UInt16

    public init(
        localHost: String = "127.0.0.1",
        incomingPort: UInt16 = 9001,
        remoteHost: String = "127.0.0.1",
        outgoingPort: UInt16 = 7001
    ) {
        self.localHost = localHost
        self.incomingPort = incomingPort
        self.remoteHost = remoteHost
        self.outgoingPort = outgoingPort
    }
}

/// OSC UDP 套接字运行状态。
public enum OSCTransportState: Equatable, Sendable {
    case stopped
    case listening(localHost: String, incomingPort: UInt16, remoteHost: String, outgoingPort: UInt16)
    case portInUse(port: UInt16, message: String)
    case failed(String)

    public var isListening: Bool {
        if case .listening = self {
            return true
        }
        return false
    }
}

/// OSC UDP 传输层产出的纯值 `Sendable` 事件流元素。
public enum OSCInboundEvent: Equatable, Sendable {
    case transportStateChanged(OSCTransportState)
    case messagesReceived([OSCMessage], rawByteCount: Int, timestamp: TimeInterval)
    case diagnostic(direction: String, summary: String, timestamp: TimeInterval)
}

/// 单套接字非阻塞 BSD `SOCK_DGRAM` OSC 收发层。
///
/// 并发安全与系统级约束：
/// - 内部所有可变状态严格隔离于私有串行队列 `"com.tourmix.osc"`。
/// - 绑定本地 `127.0.0.1:incomingPort` 时**仅设 `SO_REUSEADDR`，严禁设置 `SO_REUSEPORT`**，
///   确保 `9001` 被 TouchOSC / Companion 等第三方程序占用时诚实返回 `EADDRINUSE` 并上报 `.portInUse`。
/// - `DispatchSourceRead` 一旦创建，文件描述符 `fd` **唯一且仅在 `setCancelHandler` 内调用 `Darwin.close(fd)`**，
///   动态重绑端口 `reconfigure(...)` 在旧 `fd` 完成关闭回调后顺序绑定新套接字，杜绝 FD 重用竞态与自冲突。
public final class OSCUDPTransport: @unchecked Sendable {
    public nonisolated let events: AsyncStream<OSCInboundEvent>

    private let continuation: AsyncStream<OSCInboundEvent>.Continuation
    private let queue = DispatchQueue(label: "com.tourmix.osc", qos: .userInteractive)

    // 以下状态仅在 `queue` 上读写
    private var configuration: OSCTransportConfiguration
    private var isStarted: Bool = false
    private var activeFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var remoteSockAddr: sockaddr_in?
    private var pendingRebindAfterClose: Bool = false
    private var receiveBuffer = [UInt8](repeating: 0, count: 65536)

    public init(
        host: String = "127.0.0.1",
        outgoingPort: UInt16 = 7001,
        incomingPort: UInt16 = 9001
    ) {
        self.configuration = OSCTransportConfiguration(
            localHost: "127.0.0.1",
            incomingPort: incomingPort,
            remoteHost: host,
            outgoingPort: outgoingPort
        )
        var capturedContinuation: AsyncStream<OSCInboundEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(512)) { cont in
            capturedContinuation = cont
        }
        self.continuation = capturedContinuation
    }

    deinit {
        readSource?.cancel()
        continuation.finish()
    }

    /// 启动本地 UDP 监听并准备发送目标地址。
    public nonisolated func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isStarted = true
            if self.readSource == nil {
                self.openAndBindSocketLocked()
            }
        }
    }

    /// 停止 UDP 监听并安全关闭底层套接字。
    public nonisolated func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isStarted = false
            self.pendingRebindAfterClose = false
            if let source = self.readSource {
                self.readSource = nil
                self.activeFD = -1
                source.cancel()
            } else {
                self.emitStateLocked(.stopped)
            }
        }
    }

    /// 运行时动态切换目标地址、发送端口（默认 `7001`）与本地监听端口（默认 `9001`）。
    public nonisolated func reconfigure(
        host: String,
        outgoingPort: UInt16,
        incomingPort: UInt16
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.configuration = OSCTransportConfiguration(
                localHost: "127.0.0.1",
                incomingPort: incomingPort,
                remoteHost: host,
                outgoingPort: outgoingPort
            )
            self.isStarted = true
            if let source = self.readSource {
                self.pendingRebindAfterClose = true
                self.readSource = nil
                self.activeFD = -1
                source.cancel()
            } else {
                self.pendingRebindAfterClose = false
                self.openAndBindSocketLocked()
            }
        }
    }

    /// 异步编码并发送单条 `OSCMessage`。
    public nonisolated func send(_ message: OSCMessage) {
        let payload = OSCCodec.encode(message)
        let summary = "\(message.address) \(Self.describeArguments(message.arguments))"
        sendRawData(payload, diagnosticSummary: summary)
    }

    /// 异步发送已编码的原始 OSC 数据报。
    public nonisolated func sendRawData(_ data: Data, diagnosticSummary: String? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.activeFD >= 0, var dest = self.remoteSockAddr else {
                return
            }
            let sentBytes = data.withUnsafeBytes { rawBuf -> Int in
                guard let base = rawBuf.baseAddress else { return -1 }
                return withUnsafePointer(to: &dest) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        Darwin.sendto(
                            self.activeFD,
                            base,
                            rawBuf.count,
                            0,
                            sockPtr,
                            socklen_t(MemoryLayout<sockaddr_in>.size)
                        )
                    }
                }
            }

            let now = ProcessInfo.processInfo.systemUptime
            if sentBytes < 0 {
                let err = Darwin.errno
                if err != EAGAIN && err != EWOULDBLOCK {
                    let msg = String(cString: Darwin.strerror(err))
                    self.continuation.yield(
                        .diagnostic(
                            direction: "TX-ERR",
                            summary: "sendto \(self.configuration.remoteHost):\(self.configuration.outgoingPort) 失败 (\(err)): \(msg)",
                            timestamp: now
                        )
                    )
                }
            } else if let summary = diagnosticSummary {
                self.continuation.yield(
                    .diagnostic(direction: "TX", summary: summary, timestamp: now)
                )
            }
        }
    }

    // MARK: - Private Serial Queue Implementation

    private func openAndBindSocketLocked() {
        guard configuration.incomingPort > 0, configuration.outgoingPort > 0 else {
            emitStateLocked(.failed("OSC 端口号无效（必须为 1...65535）"))
            return
        }

        guard let localAddr = Self.makeIPv4SockAddr(host: configuration.localHost, port: configuration.incomingPort) else {
            emitStateLocked(.failed("无效的本地监听地址：\(configuration.localHost)"))
            return
        }

        guard let remoteAddr = Self.makeIPv4SockAddr(host: configuration.remoteHost, port: configuration.outgoingPort) else {
            emitStateLocked(.failed("无效的 TotalMix 目标地址：\(configuration.remoteHost)"))
            return
        }

        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            let err = Darwin.errno
            let msg = String(cString: Darwin.strerror(err))
            emitStateLocked(.failed("创建 UDP 套接字失败 (\(err)): \(msg)"))
            return
        }

        // 设置 FD_CLOEXEC 与 O_NONBLOCK
        let fdFlags = Darwin.fcntl(fd, F_GETFD)
        if fdFlags >= 0 {
            _ = Darwin.fcntl(fd, F_SETFD, fdFlags | FD_CLOEXEC)
        }
        let statusFlags = Darwin.fcntl(fd, F_GETFL)
        if statusFlags >= 0 {
            _ = Darwin.fcntl(fd, F_SETFL, statusFlags | O_NONBLOCK)
        }

        // 仅设 SO_REUSEADDR 与 SO_NOSIGPIPE，严禁设置 SO_REUSEPORT！
        var reuseAddr: Int32 = 1
        _ = Darwin.setsockopt(
            fd,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuseAddr,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var noSigPipe: Int32 = 1
        _ = Darwin.setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var mutableLocal = localAddr
        let bindResult = withUnsafePointer(to: &mutableLocal) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if bindResult != 0 {
            let err = Darwin.errno
            // 此时 DispatchSourceRead 尚未创建，直接关闭临时 fd
            Darwin.close(fd)
            if err == EADDRINUSE {
                let message = "OSC 接收端口 \(configuration.incomingPort) 已被其他应用占用（如 TouchOSC / Companion），请关闭占用程序或在设置中改用 7002 / 9002 端口对。"
                emitStateLocked(.portInUse(port: configuration.incomingPort, message: message))
            } else {
                let reason = String(cString: Darwin.strerror(err))
                emitStateLocked(.failed("绑定本地 UDP 端口 \(configuration.incomingPort) 失败 (\(err)): \(reason)"))
            }
            return
        }

        self.remoteSockAddr = remoteAddr
        self.activeFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drainIncomingDatagramsLocked(fd: fd)
        }
        // DispatchSourceRead 一旦挂载，唯一在此处关闭 fd
        source.setCancelHandler { [weak self] in
            Darwin.close(fd)
            self?.didCancelSocketLocked()
        }
        self.readSource = source
        source.resume()

        emitStateLocked(
            .listening(
                localHost: configuration.localHost,
                incomingPort: configuration.incomingPort,
                remoteHost: configuration.remoteHost,
                outgoingPort: configuration.outgoingPort
            )
        )
    }

    private func didCancelSocketLocked() {
        if pendingRebindAfterClose && isStarted {
            pendingRebindAfterClose = false
            openAndBindSocketLocked()
        } else if !isStarted && readSource == nil {
            emitStateLocked(.stopped)
        }
    }

    private func drainIncomingDatagramsLocked(fd: Int32) {
        while true {
            var senderAddr = sockaddr_in()
            var senderLen = socklen_t(MemoryLayout<sockaddr_in>.size)

            let bytesRead = receiveBuffer.withUnsafeMutableBytes { rawBuf -> Int in
                guard let base = rawBuf.baseAddress else { return -1 }
                return withUnsafeMutablePointer(to: &senderAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        Darwin.recvfrom(fd, base, rawBuf.count, 0, sockPtr, &senderLen)
                    }
                }
            }

            if bytesRead > 0 {
                let packetData = Data(receiveBuffer[0..<bytesRead])
                let now = ProcessInfo.processInfo.systemUptime
                do {
                    let messages = try OSCCodec.decodeMessages(packetData)
                    if !messages.isEmpty {
                        continuation.yield(
                            .messagesReceived(messages, rawByteCount: bytesRead, timestamp: now)
                        )
                    }
                } catch {
                    continuation.yield(
                        .diagnostic(
                            direction: "RX-WARN",
                            summary: "忽略畸形 OSC 数据包 (\(bytesRead) B): \(error.localizedDescription)",
                            timestamp: now
                        )
                    )
                }
                continue
            }

            if bytesRead == 0 {
                break
            }

            let err = Darwin.errno
            if err == EINTR {
                continue
            }
            if err == EAGAIN || err == EWOULDBLOCK {
                break
            }

            let now = ProcessInfo.processInfo.systemUptime
            let msg = String(cString: Darwin.strerror(err))
            continuation.yield(
                .diagnostic(direction: "RX-ERR", summary: "recvfrom 异常 (\(err)): \(msg)", timestamp: now)
            )
            break
        }
    }

    private func emitStateLocked(_ state: OSCTransportState) {
        continuation.yield(.transportStateChanged(state))
    }

    private static func makeIPv4SockAddr(host: String, port: UInt16) -> sockaddr_in? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedHost: String
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare("localhost") == .orderedSame {
            resolvedHost = "127.0.0.1"
        } else {
            resolvedHost = trimmed
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian

        let ok = resolvedHost.withCString { cStr in
            Darwin.inet_pton(AF_INET, cStr, &addr.sin_addr)
        }
        guard ok == 1 else {
            return nil
        }
        return addr
    }

    private static func describeArguments(_ args: [OSCArgument]) -> String {
        args.map { arg in
            switch arg {
            case .float32(let f):
                return String(format: "%.3ff", f)
            case .int32(let i):
                return "\(i)i"
            case .string(let s):
                return "\"\(s)\""
            case .bool(let b):
                return b ? "true" : "false"
            }
        }.joined(separator: " ")
    }
}
