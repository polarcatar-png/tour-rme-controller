import AppKit
import Darwin
import Foundation
import IOKit
import IOKit.serial

private func tourBoxFirstMatchCallback(
    refcon: UnsafeMutableRawPointer?,
    iterator: io_iterator_t
) {
    guard let refcon else { return }
    let runtime = Unmanaged<TourBoxSerialRuntime>.fromOpaque(refcon).takeUnretainedValue()
    runtime.handleDevicesAdded(iterator)
}

private func tourBoxTerminatedCallback(
    refcon: UnsafeMutableRawPointer?,
    iterator: io_iterator_t
) {
    guard let refcon else { return }
    let runtime = Unmanaged<TourBoxSerialRuntime>.fromOpaque(refcon).takeUnretainedValue()
    runtime.handleDevicesRemoved(iterator)
}

/// TourBox Lite 原生串口连接与 IOKit 热插拔/睡眠唤醒自愈服务。
///
/// 并发模型（Swift 6 Strict Concurrency）：
/// - 所有 IOKit 回调、POSIX 串口读写、分阶段握手定时器均严格串行运行于内部私有队列 `"com.tourmix.serial"`；
/// - 对外暴露 `nonisolated` 方法与 `AsyncStream<TourBoxSerialEvent>`，零锁争用、零跨线程可变状态共享。
public final class TourBoxSerialService: Sendable {
    public nonisolated let events: AsyncStream<TourBoxSerialEvent>

    private let serialQueue = DispatchQueue(label: "com.tourmix.serial", qos: .userInteractive)
    private let continuation: AsyncStream<TourBoxSerialEvent>.Continuation
    private let runtime: TourBoxSerialRuntime

    public init() {
        let (stream, continuation) = AsyncStream<TourBoxSerialEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.events = stream
        self.continuation = continuation
        self.runtime = TourBoxSerialRuntime(
            serialQueue: serialQueue,
            continuation: continuation
        )
    }

    deinit {
        let runtime = self.runtime
        let continuation = self.continuation
        serialQueue.async {
            runtime.stop()
            continuation.finish()
        }
    }

    /// 启动 IOKit 热插拔监听、系统睡眠/唤醒自愈订阅并立即探测已连接设备。
    public nonisolated func start() {
        let runtime = self.runtime
        serialQueue.async {
            runtime.start()
        }
    }

    /// 停止监听并安全释放串口与 IOKit 资源。
    public nonisolated func stop() {
        let runtime = self.runtime
        serialQueue.async {
            runtime.stop()
        }
    }

    /// 立即断开当前连接并重新扫描握手（用于 UI「立即重连」按钮）。
    public nonisolated func reconnectNow() {
        let runtime = self.runtime
        serialQueue.async {
            runtime.reconnectNow()
        }
    }
}

// MARK: - SerialQueue-Confined Runtime

private final class TourBoxSerialRuntime: @unchecked Sendable {
    private static let busyRetryInterval: TimeInterval = 2.0
    private static let wakeRescanDelay: TimeInterval = 1.5
    private static let dtrSettleDelayMs: Int = 20

    private let serialQueue: DispatchQueue
    private let continuation: AsyncStream<TourBoxSerialEvent>.Continuation

    private var isRunning: Bool = false
    private var connectionState: TourBoxConnectionState = .disconnected
    private var connectionGeneration: UInt64 = 0

    // IOKit notification state (strictly confined to serialQueue)
    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0

    // POSIX FD & DispatchSources (Darwin.close(fd) ONLY inside readSource.setCancelHandler!)
    private var activeFD: Int32 = -1
    private var currentPortPath: String?
    private var readSource: DispatchSourceRead?
    private var protocolTimer: DispatchSourceTimer?
    private var busyRetryTimer: DispatchSourceTimer?

    // Protocol state machine & pressed button tracker for safe reset release
    private var filter = TourBoxStreamFilter()
    private var activePressedButtons: Set<TourBoxButton> = []

    // NSWorkspace sleep/wake tokens
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    init(
        serialQueue: DispatchQueue,
        continuation: AsyncStream<TourBoxSerialEvent>.Continuation
    ) {
        self.serialQueue = serialQueue
        self.continuation = continuation
    }

    static func monotonicNow() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        setupWorkspaceNotifications()
        setupIOKitNotifications()
        scanAndConnectIfNeeded()
    }

    func stop() {
        guard isRunning else {
            cancelTimers()
            closeActivePort(newState: nil)
            teardownIOKitNotifications()
            teardownWorkspaceNotifications()
            return
        }
        isRunning = false

        cancelTimers()
        releaseHeldButtonsOnReset(now: Self.monotonicNow())
        closeActivePort(newState: .disconnected)
        teardownIOKitNotifications()
        teardownWorkspaceNotifications()
    }

    func reconnectNow() {
        if !isRunning {
            start()
            return
        }
        emitDiagnostic(direction: "SYS", hex: "", note: "收到手动重连请求，重新扫描 TourBox 串口")
        cancelTimers()
        releaseHeldButtonsOnReset(now: Self.monotonicNow())
        closeActivePort(newState: .disconnected)
        scanAndConnectIfNeeded()
    }

    // MARK: - NSWorkspace Sleep / Wake Self-Healing

    private func setupWorkspaceNotifications() {
        guard sleepObserver == nil, wakeObserver == nil else { return }
        let center = NSWorkspace.shared.notificationCenter

        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.serialQueue.async {
                self.handleSystemWillSleep()
            }
        }

        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.serialQueue.async {
                self.handleSystemDidWake()
            }
        }
    }

    private func teardownWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        if let sleepObserver {
            center.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }
        if let wakeObserver {
            center.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    private func handleSystemWillSleep() {
        guard isRunning else { return }
        emitDiagnostic(direction: "SYS", hex: "", note: "系统即将休眠，释放按键状态并主动关闭串口")
        cancelTimers()
        releaseHeldButtonsOnReset(now: Self.monotonicNow())
        closeActivePort(newState: .disconnected)
    }

    private func handleSystemDidWake() {
        guard isRunning else { return }
        emitDiagnostic(direction: "SYS", hex: "", note: "系统已唤醒，立即扫描串口并安排 1.5s 延时兜底复扫")
        scanAndConnectIfNeeded()

        serialQueue.asyncAfter(deadline: .now() + Self.wakeRescanDelay) { [weak self] in
            guard let self, self.isRunning else { return }
            self.scanAndConnectIfNeeded()
        }
    }

    // MARK: - IOKit Hotplug Registration & Parent Search

    private func setupIOKitNotifications() {
        guard notifyPort == nil else { return }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            updateState(.error("无法创建 IOKit 通知端口"))
            return
        }
        IONotificationPortSetDispatchQueue(port, serialQueue)
        notifyPort = port

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // 必须独立创建两次 Matching 字典（IOServiceAddMatchingNotification 会消费字典引用！）
        if let matchAdded = IOServiceMatching(kIOSerialBSDServiceValue) {
            let kr = IOServiceAddMatchingNotification(
                port,
                kIOFirstMatchNotification,
                matchAdded,
                tourBoxFirstMatchCallback,
                refcon,
                &addedIterator
            )
            if kr == KERN_SUCCESS, addedIterator != 0 {
                // 立即同步排空迭代器以武装热插拔通知
                handleDevicesAdded(addedIterator)
            }
        }

        if let matchRemoved = IOServiceMatching(kIOSerialBSDServiceValue) {
            let kr = IOServiceAddMatchingNotification(
                port,
                kIOTerminatedNotification,
                matchRemoved,
                tourBoxTerminatedCallback,
                refcon,
                &removedIterator
            )
            if kr == KERN_SUCCESS, removedIterator != 0 {
                // 首次仅同步排空以武装拔出通知，不对既有终止快照做断开动作
                drainIteratorArmingOnly(removedIterator)
            }
        }
    }

    private func teardownIOKitNotifications() {
        if addedIterator != 0 {
            IOObjectRelease(addedIterator)
            addedIterator = 0
        }
        if removedIterator != 0 {
            IOObjectRelease(removedIterator)
            removedIterator = 0
        }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
    }

    private func drainIteratorArmingOnly(_ iterator: io_iterator_t) {
        while true {
            let service = IOIteratorNext(iterator)
            guard service != IO_OBJECT_NULL else { break }
            IOObjectRelease(service)
        }
    }

    fileprivate func handleDevicesAdded(_ iterator: io_iterator_t) {
        var matchedPath: String?
        while true {
            let service = IOIteratorNext(iterator)
            guard service != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(service) }

            if let path = Self.matchingTourBoxCalloutPath(for: service) {
                matchedPath = path
            }
        }

        guard isRunning, let path = matchedPath else { return }
        if activeFD < 0 {
            openAndConfigurePort(path)
        }
    }

    fileprivate func handleDevicesRemoved(_ iterator: io_iterator_t) {
        var removedPaths: Set<String> = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(service) }

            if let callout = Self.extractCalloutPath(from: service) {
                removedPaths.insert(callout)
            }
        }

        guard isRunning, !removedPaths.isEmpty else { return }
        if let activePath = currentPortPath ?? connectionState.port,
           removedPaths.contains(activePath) {
            emitDiagnostic(direction: "SYS", hex: "", note: "IOKit 检测到串口设备移除: \(activePath)")
            cancelTimers()
            releaseHeldButtonsOnReset(now: Self.monotonicNow())
            closeActivePort(newState: .disconnected)
        }
    }

    private func scanAndConnectIfNeeded() {
        guard isRunning, activeFD < 0 else { return }
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return }

        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard kr == KERN_SUCCESS, iterator != 0 else { return }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(service) }

            if let path = Self.matchingTourBoxCalloutPath(for: service) {
                openAndConfigurePort(path)
                return
            }
        }
    }

    private static func extractCalloutPath(from service: io_service_t) -> String? {
        guard let raw = IORegistryEntryCreateCFProperty(
            service,
            kIOCalloutDeviceKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String, !raw.isEmpty else {
            return nil
        }
        return raw
    }

    private static func matchingTourBoxCalloutPath(for service: io_service_t) -> String? {
        guard let calloutPath = extractCalloutPath(from: service) else {
            return nil
        }

        let searchOptions = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        let vendorID = (IORegistryEntrySearchCFProperty(
            service,
            kIOServicePlane,
            "idVendor" as CFString,
            kCFAllocatorDefault,
            searchOptions
        ) as? NSNumber)?.intValue

        let productID = (IORegistryEntrySearchCFProperty(
            service,
            kIOServicePlane,
            "idProduct" as CFString,
            kCFAllocatorDefault,
            searchOptions
        ) as? NSNumber)?.intValue

        let vendorName = IORegistryEntrySearchCFProperty(
            service,
            kIOServicePlane,
            "USB Vendor Name" as CFString,
            kCFAllocatorDefault,
            searchOptions
        ) as? String

        let productName = IORegistryEntrySearchCFProperty(
            service,
            kIOServicePlane,
            "USB Product Name" as CFString,
            kCFAllocatorDefault,
            searchOptions
        ) as? String

        guard TourBoxProtocol.isSupportedDevice(
            vendorID: vendorID,
            productID: productID,
            vendorName: vendorName,
            productName: productName
        ) else {
            return nil
        }
        return calloutPath
    }

    // MARK: - POSIX Serial Open, Termios, DTR/RTS & DispatchSourceRead

    private func openAndConfigurePort(_ path: String) {
        guard isRunning else { return }
        if activeFD >= 0, currentPortPath == path {
            return
        }

        cancelBusyRetryTimer()
        cancelProtocolTimer()
        closeActivePort(newState: nil)

        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            let err = errno
            handleOpenFailure(port: path, errnoValue: err)
            return
        }

        // 1. 立即加 TIOCEXCL 排他锁（防止双进程瓜分单字节流；若官方软件正在运行返回 EBUSY）
        if ioctl(fd, UInt(TIOCEXCL)) != 0 {
            let err = errno
            Darwin.close(fd)
            handleOpenFailure(port: path, errnoValue: err)
            return
        }

        // 2. 标准 Darwin termios 初始化：tcgetattr -> cfmakeraw -> cfsetspeed -> 补齐 8N1 无流控 -> tcsetattr
        var attrs = termios()
        guard tcgetattr(fd, &attrs) == 0 else {
            let err = errno
            Darwin.close(fd)
            updateState(.error("读取串口 termios 失败 (errno=\(err))"))
            return
        }

        cfmakeraw(&attrs)
        cfsetspeed(&attrs, speed_t(B115200))
        attrs.c_cflag |= tcflag_t(CLOCAL | CREAD | CS8)
        attrs.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CRTSCTS)
        withUnsafeMutableBytes(of: &attrs.c_cc) { cc in
            // 关键：XNU ttyread 在 VMIN=0, VTIME=0 时遇空缓冲会返回 0 而非 -1 (EAGAIN)，导致误判拔线 EOF！
            // 必须设 VMIN=1, VTIME=0 配合 O_NONBLOCK，使空缓冲稳定返回 EAGAIN，仅在真实拔线 EV_EOF 时返回 0。
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }

        guard tcsetattr(fd, TCSANOW, &attrs) == 0 else {
            let err = errno
            Darwin.close(fd)
            updateState(.error("配置串口 115200 8N1 失败 (errno=\(err))"))
            return
        }

        let statusFlags = Darwin.fcntl(fd, F_GETFL)
        if statusFlags >= 0 {
            _ = Darwin.fcntl(fd, F_SETFL, statusFlags | O_NONBLOCK)
        }

        // 3. 显式拉高 CDC-ACM 控制线 DTR | RTS
        _ = ioctl(fd, UInt(TIOCSDTR))
        var modemBits: Int32 = TIOCM_DTR | TIOCM_RTS
        _ = withUnsafeMutablePointer(to: &modemBits) { ptr in
            ioctl(fd, UInt(TIOCMSET), ptr)
        }

        // 4. 建立 DispatchSourceRead —— 自此之后严禁在其它任何位置调用 Darwin.close(fd)，唯一在 setCancelHandler 关闭！
        connectionGeneration &+= 1
        let generation = connectionGeneration
        activeFD = fd
        currentPortPath = path
        _ = filter.reset()
        activePressedButtons.removeAll()
        updateState(.connecting(port: path))
        emitDiagnostic(direction: "SYS", hex: "", note: "已打开串口并加排他锁: \(path)，等待 20ms 稳定后启动握手")

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: serialQueue)
        source.setEventHandler { [weak self] in
            self?.handleReadable(fd: fd, generation: generation, portPath: path)
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        readSource = source
        source.resume()

        // 5. 延时 20ms 待 DTR/RTS 稳定后清空内核缓冲并启动四阶段握手
        serialQueue.asyncAfter(deadline: .now() + .milliseconds(Self.dtrSettleDelayMs)) { [weak self] in
            guard let self,
                  self.isRunning,
                  self.connectionGeneration == generation,
                  self.activeFD == fd else {
                return
            }
            _ = tcflush(fd, TCIOFLUSH)
            let now = Self.monotonicNow()
            let result = self.filter.beginHandshake(now: now)
            self.applyFilterResult(result, generation: generation, portPath: path, now: now)
        }
    }

    private func handleOpenFailure(port: String, errnoValue: Int32) {
        if errnoValue == EBUSY {
            let message = "串口被占用（请先退出官方 TourBox Console 软件，退出后将自动重连）"
            updateState(.portBusy(port: port, message: message))
            emitDiagnostic(direction: "SYS", hex: "", note: "端口 \(port) 返回 EBUSY，将于 \(Self.busyRetryInterval)s 后自动重试")
            scheduleBusyRetry(for: port)
        } else if errnoValue == ENOENT || errnoValue == ENXIO {
            updateState(.disconnected)
        } else {
            let errText = String(cString: strerror(errnoValue))
            updateState(.error("打开串口失败 (\(errText), errno=\(errnoValue))"))
        }
    }

    private func scheduleBusyRetry(for port: String) {
        cancelBusyRetryTimer()
        let timer = DispatchSource.makeTimerSource(queue: serialQueue)
        timer.schedule(
            deadline: .now() + Self.busyRetryInterval,
            repeating: Self.busyRetryInterval,
            leeway: .milliseconds(100)
        )
        timer.setEventHandler { [weak self] in
            guard let self, self.isRunning, self.activeFD < 0 else { return }
            if FileManager.default.fileExists(atPath: port) {
                self.openAndConfigurePort(port)
            } else {
                self.cancelBusyRetryTimer()
                self.updateState(.disconnected)
            }
        }
        busyRetryTimer = timer
        timer.resume()
    }

    private func handleReadable(fd: Int32, generation: UInt64, portPath: String) {
        guard connectionGeneration == generation, activeFD == fd else { return }
        var buffer = [UInt8](repeating: 0, count: 256)

        while connectionGeneration == generation, activeFD == fd {
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuf -> Int in
                guard let base = rawBuf.baseAddress else { return -1 }
                return Darwin.read(fd, base, rawBuf.count)
            }

            if bytesRead > 0 {
                let chunk = Array(buffer.prefix(bytesRead))
                let now = Self.monotonicNow()
                let result = filter.ingest(chunk, now: now)
                applyFilterResult(result, generation: generation, portPath: portPath, now: now)
            } else if bytesRead == 0 {
                // 物理拔线触发 EV_EOF（read 返回 0）：必须立即 cancel readSource 防止 kqueue 水平触发 100% CPU 死循环！
                emitDiagnostic(direction: "SYS", hex: "", note: "串口读取 EOF，设备已拔出: \(portPath)")
                cancelProtocolTimer()
                releaseHeldButtonsOnReset(now: Self.monotonicNow())
                closeActivePort(newState: .disconnected)
                break
            } else {
                let err = errno
                if err == EINTR {
                    continue
                }
                if err == EAGAIN || err == EWOULDBLOCK {
                    break
                }
                emitDiagnostic(direction: "SYS", hex: "", note: "串口读取异常中断 (errno=\(err)): \(portPath)")
                cancelProtocolTimer()
                releaseHeldButtonsOnReset(now: Self.monotonicNow())
                closeActivePort(newState: .disconnected)
                break
            }
        }
    }

    private func applyFilterResult(
        _ result: TourBoxStreamFilter.FilterResult,
        generation: UInt64,
        portPath: String,
        now: TimeInterval
    ) {
        guard connectionGeneration == generation, activeFD >= 0 else { return }

        for diag in result.diagnostics {
            emitDiagnostic(direction: diag.direction, hex: diag.hex, note: diag.note)
        }

        for frame in result.commandsToWrite {
            guard writeAll(frame, to: activeFD) else {
                emitDiagnostic(direction: "SYS", hex: "", note: "写入握手/配置帧失败，关闭当前串口")
                cancelProtocolTimer()
                releaseHeldButtonsOnReset(now: now)
                closeActivePort(newState: .disconnected)
                return
            }
        }

        if result.resetStateMachine {
            releaseHeldButtonsOnReset(now: now)
        }

        if result.didEnterStreaming {
            updateState(.connected(port: portPath))
        }

        for sample in result.inputs {
            switch sample.decoded {
            case .buttonPress(let button):
                activePressedButtons.insert(button)
            case .buttonRelease(let button):
                activePressedButtons.remove(button)
            case .rotaryStep, .rotaryStop:
                break
            }
            continuation.yield(.input(sample.decoded, rawByte: sample.rawByte, timestamp: sample.timestamp))
        }

        scheduleProtocolTimerIfNeeded(generation: generation, portPath: portPath)
    }

    private func scheduleProtocolTimerIfNeeded(generation: UInt64, portPath: String) {
        cancelProtocolTimer()
        guard connectionGeneration == generation,
              activeFD >= 0,
              let deadline = filter.nextDeadline else {
            return
        }

        let delay = max(0.0, deadline - Self.monotonicNow())
        let timer = DispatchSource.makeTimerSource(queue: serialQueue)
        timer.schedule(deadline: .now() + delay, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.isRunning,
                  self.connectionGeneration == generation,
                  self.activeFD >= 0 else {
                return
            }
            let now = Self.monotonicNow()
            let result = self.filter.advanceTime(now: now)
            self.applyFilterResult(result, generation: generation, portPath: portPath, now: now)
        }
        protocolTimer = timer
        timer.resume()
    }

    /// 带偏移循环完整写满帧字节（防止 O_NONBLOCK 下 94B 配置帧出现部分写）。
    private func writeAll(_ bytes: [UInt8], to fd: Int32) -> Bool {
        guard fd >= 0, !bytes.isEmpty else { return fd >= 0 }
        var offset = 0
        var eagainRetries = 0

        return bytes.withUnsafeBytes { rawBuf -> Bool in
            guard let base = rawBuf.baseAddress else { return false }
            while offset < bytes.count {
                let written = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                if written > 0 {
                    offset += written
                    eagainRetries = 0
                } else if written < 0 {
                    let err = errno
                    if err == EINTR {
                        continue
                    }
                    if (err == EAGAIN || err == EWOULDBLOCK), eagainRetries < 10 {
                        eagainRetries += 1
                        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        _ = Darwin.poll(&pfd, 1, 10)
                        continue
                    }
                    return false
                } else {
                    return false
                }
            }
            return true
        }
    }

    private func releaseHeldButtonsOnReset(now: TimeInterval) {
        guard !activePressedButtons.isEmpty else { return }
        let pending = activePressedButtons
        activePressedButtons.removeAll()
        for button in TourBoxButton.allCases where pending.contains(button) {
            continuation.yield(.input(.buttonRelease(button), rawByte: button.releaseByte, timestamp: now))
        }
    }

    private func closeActivePort(newState: TourBoxConnectionState?) {
        connectionGeneration &+= 1
        activeFD = -1
        currentPortPath = nil
        _ = filter.reset()

        if let source = readSource {
            readSource = nil
            // 唯一触发 Darwin.close(fd) 的出口（位于 source.setCancelHandler 内）
            source.cancel()
        }

        if let newState {
            updateState(newState)
        }
    }

    private func cancelProtocolTimer() {
        if let timer = protocolTimer {
            protocolTimer = nil
            timer.cancel()
        }
    }

    private func cancelBusyRetryTimer() {
        if let timer = busyRetryTimer {
            busyRetryTimer = nil
            timer.cancel()
        }
    }

    private func cancelTimers() {
        cancelProtocolTimer()
        cancelBusyRetryTimer()
    }

    private func updateState(_ newState: TourBoxConnectionState) {
        guard connectionState != newState else { return }
        connectionState = newState
        continuation.yield(.stateChanged(newState))
    }

    private func emitDiagnostic(direction: String, hex: String, note: String) {
        continuation.yield(.rawDiagnostic(direction: direction, hex: hex, note: note))
    }
}
