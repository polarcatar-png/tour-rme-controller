import AppKit
import ApplicationServices
import Foundation

/// 可序列化的 macOS 键盘组合快捷键模型。
public struct KeyCombo: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt16
    public var control: Bool
    public var option: Bool
    public var shift: Bool
    public var command: Bool
    public var displayLabel: String

    public init(
        keyCode: UInt16,
        control: Bool = false,
        option: Bool = false,
        shift: Bool = false,
        command: Bool = false,
        displayLabel: String? = nil
    ) {
        self.keyCode = keyCode
        self.control = control
        self.option = option
        self.shift = shift
        self.command = command
        if let displayLabel, !displayLabel.isEmpty {
            self.displayLabel = displayLabel
        } else {
            self.displayLabel = Self.formatDisplayLabel(
                keyCode: keyCode,
                control: control,
                option: option,
                shift: shift,
                command: command
            )
        }
    }

    /// 判断该键码本身是否为独立的修饰键（如单独绑定 Left Shift / Option / Command / Control）。
    public static func standaloneModifierFlag(for keyCode: UInt16) -> CGEventFlags? {
        switch keyCode {
        case 0x37, 0x36: return .maskCommand   // 55 Left Cmd, 54 Right Cmd
        case 0x38, 0x3C: return .maskShift     // 56 Left Shift, 60 Right Shift
        case 0x3A, 0x3D: return .maskAlternate // 58 Left Option, 61 Right Option
        case 0x3B, 0x3E: return .maskControl   // 59 Left Control, 62 Right Control
        case 0x39: return .maskAlphaShift      // 57 Caps Lock
        case 0x3F: return .maskSecondaryFn     // 63 Fn
        default: return nil
        }
    }

    /// 该绑定是否为不带额外组合修饰位的纯单修饰键（如单独按住 TourBox 键等于按住 Shift）。
    public var isStandaloneModifierKey: Bool {
        Self.standaloneModifierFlag(for: keyCode) != nil && !control && !option && !shift && !command
    }

    /// 对应的 `CGEventFlags` 修饰掩码。
    public var cgEventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if control { flags.insert(.maskControl) }
        if option { flags.insert(.maskAlternate) }
        if shift { flags.insert(.maskShift) }
        if command { flags.insert(.maskCommand) }
        return flags
    }

    /// 将修饰位与虚拟键码格式化为标准 macOS 按键/快捷键符号串（支持单键如 `"B"`、`"Space"`、`"⇧ Shift"` 及组合键 `"⌃⌥⌘Z"`）。
    public static func formatDisplayLabel(
        keyCode: UInt16,
        control: Bool,
        option: Bool,
        shift: Bool,
        command: Bool
    ) -> String {
        if standaloneModifierFlag(for: keyCode) != nil && !control && !option && !shift && !command {
            return keySymbol(for: keyCode)
        }
        var parts = ""
        if control { parts += "⌃" }
        if option { parts += "⌥" }
        if shift { parts += "⇧" }
        if command { parts += "⌘" }
        parts += keySymbol(for: keyCode)
        return parts
    }

    /// 内置常用 macOS Carbon 虚拟键码（`kVK_*`）到可读符号名的确定性映射表。
    public static func keySymbol(for keyCode: UInt16) -> String {
        if let symbol = virtualKeySymbols[keyCode] {
            return symbol
        }
        return "Key(\(keyCode))"
    }

    private static let virtualKeySymbols: [UInt16: String] = [
        // Standalone Modifier Keys
        0x37: "⌘ Command", 0x36: "⌘ Right Cmd",
        0x38: "⇧ Shift", 0x3C: "⇧ Right Shift",
        0x3A: "⌥ Option", 0x3D: "⌥ Right Opt",
        0x3B: "⌃ Control", 0x3E: "⌃ Right Ctrl",
        0x39: "⇪ CapsLock", 0x3F: "fn",

        // ANSI Letters & Digits
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G",
        0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q",
        0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T", 0x12: "1",
        0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=",
        0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]",
        0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P", 0x25: "L",
        0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";", 0x2A: "\\", 0x2B: ",",
        0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".", 0x32: "`",

        // Editing & Whitespace
        0x24: "↩",
        0x30: "⇥",
        0x31: "Space",
        0x33: "⌫",
        0x35: "⎋",
        0x75: "⌦",

        // Arrow & Navigation
        0x73: "↖",
        0x74: "⇞",
        0x77: "↘",
        0x79: "⇟",
        0x7B: "←",
        0x7C: "→",
        0x7D: "↓",
        0x7E: "↑",

        // Function Keys (F1..F20)
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4",
        0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8",
        0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
        0x69: "F13", 0x6B: "F14", 0x71: "F15", 0x6A: "F16",
        0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20",

        // Keypad
        0x41: "KP.", 0x43: "KP*", 0x45: "KP+", 0x47: "Clear",
        0x4B: "KP/", 0x4C: "⌤", 0x4E: "KP-", 0x51: "KP=",
        0x52: "KP0", 0x53: "KP1", 0x54: "KP2", 0x55: "KP3",
        0x56: "KP4", 0x57: "KP5", 0x58: "KP6", 0x59: "KP7",
        0x5B: "KP8", 0x5C: "KP9"
    ]
}

/// 旋钮 / 滚轮模拟触控板平滑滑动或鼠标滚轮参数模型。
public struct MouseScrollConfig: Codable, Equatable, Hashable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Identifiable, Sendable {
        /// 类触控板双指滑动（基于 `.pixel` 微帧插值的丝滑连续滚动）
        case trackpadSmooth
        /// 传统鼠标中键滚轮（基于 `.line` 的清晰刻度行滚动）
        case mouseWheelLine

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .trackpadSmooth: return "类触控板双指平滑滑动 (像素级顺滑)"
            case .mouseWheelLine: return "传统鼠标中键滚轮 (按行刻度)"
            }
        }
    }

    public enum Axis: String, Codable, CaseIterable, Identifiable, Sendable {
        case vertical
        case horizontal

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .vertical: return "上下垂直滚动 / 翻页"
            case .horizontal: return "左右水平横向滚动"
            }
        }
    }

    public var mode: Mode
    public var axis: Axis
    /// 速度档位 `1...5`（默认 `3` 标准速度）
    public var speed: Int
    /// 反转滚动方向（适配个人「自然滚动」习惯）
    public var invertDirection: Bool
    /// 快速连续滚动时自动惯性加速
    public var dynamicAcceleration: Bool

    public init(
        mode: Mode = .trackpadSmooth,
        axis: Axis = .vertical,
        speed: Int = 3,
        invertDirection: Bool = false,
        dynamicAcceleration: Bool = true
    ) {
        self.mode = mode
        self.axis = axis
        self.speed = min(5, max(1, speed))
        self.invertDirection = invertDirection
        self.dynamicAcceleration = dynamicAcceleration
    }

    public static let standard = MouseScrollConfig()
}

/// 模拟鼠标按键点击枚举（支持滚轮按下充当鼠标中键点击/按住拖拽）。
public enum MouseClickButton: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case middle
    case left
    case right
    case back
    case forward

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .middle: return "鼠标中键 (Middle Click · 支持按住拖拽/关标签)"
        case .left: return "鼠标左键 (Left Click)"
        case .right: return "鼠标右键 (Right Click)"
        case .back: return "鼠标侧键 · 后退 (Back)"
        case .forward: return "鼠标侧键 · 前进 (Forward)"
        }
    }

    public var shortSummary: String {
        switch self {
        case .middle: return "鼠标中键"
        case .left: return "鼠标左键"
        case .right: return "鼠标右键"
        case .back: return "鼠标后退"
        case .forward: return "鼠标前进"
        }
    }
}

/// 系统级媒体控制键枚举（对应 `IOKit/hidsystem/ev_keymap.h` `NX_KEYTYPE_*`）。
public enum MediaKeyAction: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case playPause
    case nextTrack
    case previousTrack
    case volumeUp
    case volumeDown
    case mute

    public var id: String { rawValue }

    /// 中文显示名称
    public var displayName: String {
        switch self {
        case .playPause: return "播放 / 暂停"
        case .nextTrack: return "下一曲"
        case .previousTrack: return "上一曲"
        case .volumeUp: return "系统音量 +"
        case .volumeDown: return "系统音量 -"
        case .mute: return "系统静音"
        }
    }

    /// 建议的 SF Symbols 图标名
    public var systemIcon: String {
        switch self {
        case .playPause: return "playpause.fill"
        case .nextTrack: return "forward.fill"
        case .previousTrack: return "backward.fill"
        case .volumeUp: return "speaker.wave.3.fill"
        case .volumeDown: return "speaker.wave.1.fill"
        case .mute: return "speaker.slash.fill"
        }
    }

    /// macOS `NX_KEYTYPE_*` 硬件事件键码
    public var nxKeyType: Int {
        switch self {
        case .volumeUp: return 0       // NX_KEYTYPE_SOUND_UP
        case .volumeDown: return 1     // NX_KEYTYPE_SOUND_DOWN
        case .mute: return 7           // NX_KEYTYPE_MUTE
        case .playPause: return 16     // NX_KEYTYPE_PLAY
        case .nextTrack: return 17     // NX_KEYTYPE_NEXT
        case .previousTrack: return 18 // NX_KEYTYPE_PREVIOUS
        }
    }
}

/// 异步脚本/命令执行结果。
public struct ScriptExecutionResult: Equatable, Sendable {
    public let succeeded: Bool
    public let exitCode: Int32
    public let output: String
    public let errorMessage: String?

    public init(succeeded: Bool, exitCode: Int32 = 0, output: String = "", errorMessage: String? = nil) {
        self.succeeded = succeeded
        self.exitCode = exitCode
        self.output = output
        self.errorMessage = errorMessage
    }
}

/// 系统快捷键、媒体键、Shell 与 AppleScript 执行器。
///
/// 隐私权限策略：
/// - 默认仅控制 RME OSC 时**完全不请求** macOS 辅助功能权限；
/// - 仅在真正执行键盘 `CGEvent` 快捷键时按需调用 `isAccessibilityTrusted(prompt:)`。
@MainActor
public final class SystemActionExecutor {
    private let privateEventSource: CGEventSource?
    private var activeHeldKeyCombos: Set<KeyCombo> = []
    private var activeHeldMouseButtons: Set<MouseClickButton> = []
    private var lastScrollTimestamp: TimeInterval?
    private var lastScrollPositive: Bool?

    public init() {
        // 使用独立 .privateState 状态源，避免物理键盘修饰位与合成事件相互污染
        self.privateEventSource = CGEventSource(stateID: .privateState)
    }

    // MARK: - Accessibility Trust Check

    /// 检查当前进程是否已获授「辅助功能（Accessibility）」权限。
    /// 使用字符串字面量 `"AXTrustedCheckOptionPrompt"` 规避 Swift 6 C 全局变量并发错误。
    public nonisolated static func checkAccessibilityTrusted(prompt: Bool = false) -> Bool {
        let options: NSDictionary = ["AXTrustedCheckOptionPrompt": prompt]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// 实例便捷方法：检查并在可选时弹出系统辅助功能授权引导。
    public func isAccessibilityTrusted(prompt: Bool = false) -> Bool {
        Self.checkAccessibilityTrusted(prompt: prompt)
    }

    /// 打开系统设置中的「隐私与安全性 -> 辅助功能」面板。
    public func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Keyboard Shortcut Synthesis

    /// 发送键盘快捷键按下事件（用于持续型按键绑定）。若未获授辅助功能权限返回 `false`。
    @discardableResult
    public func sendKeyComboDown(_ combo: KeyCombo, promptIfUntrusted: Bool = true) -> Bool {
        guard isAccessibilityTrusted(prompt: promptIfUntrusted) else {
            return false
        }
        guard postKeyboardCGEvent(combo, keyDown: true) else {
            return false
        }
        activeHeldKeyCombos.insert(combo)
        return true
    }

    /// 发送键盘快捷键释放事件（成对释放）。
    @discardableResult
    public func sendKeyComboUp(_ combo: KeyCombo) -> Bool {
        activeHeldKeyCombos.remove(combo)
        guard isAccessibilityTrusted(prompt: false) else {
            return false
        }
        return postKeyboardCGEvent(combo, keyDown: false)
    }

    /// 发送完整的单次快捷键敲击（`keyDown` 紧跟 `keyUp`，适用于旋钮步进、修饰键单击或双击触发）。
    @discardableResult
    public func sendKeyComboTap(_ combo: KeyCombo, promptIfUntrusted: Bool = true) -> Bool {
        guard isAccessibilityTrusted(prompt: promptIfUntrusted) else {
            return false
        }
        let downOK = postKeyboardCGEvent(combo, keyDown: true)
        let upOK = postKeyboardCGEvent(combo, keyDown: false)
        return downOK && upOK
    }

    /// 紧急释放所有尚未松开的合成键盘快捷键与鼠标按键（断连或休眠时调用防卡键）。
    public func releaseAllHeldKeys() {
        let pendingKeys = activeHeldKeyCombos
        let pendingMouse = activeHeldMouseButtons
        activeHeldKeyCombos.removeAll()
        activeHeldMouseButtons.removeAll()
        guard (!pendingKeys.isEmpty || !pendingMouse.isEmpty),
              isAccessibilityTrusted(prompt: false)
        else { return }

        for combo in pendingKeys {
            _ = postKeyboardCGEvent(combo, keyDown: false)
        }
        for button in pendingMouse {
            _ = postMouseButtonCGEvent(button, buttonDown: false)
        }
    }

    private func postKeyboardCGEvent(_ combo: KeyCombo, keyDown: Bool) -> Bool {
        let source = privateEventSource ?? CGEventSource(stateID: .privateState)
        guard let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(combo.keyCode),
            keyDown: keyDown
        ) else {
            return false
        }
        var flags = combo.cgEventFlags
        if let selfModFlag = KeyCombo.standaloneModifierFlag(for: combo.keyCode) {
            if keyDown {
                flags.insert(selfModFlag)
            } else {
                flags.remove(selfModFlag)
            }
        }
        event.flags = flags
        event.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - Trackpad Smooth Scroll & Mouse Wheel Synthesis

    /// 发送一次滚轮 / 双指滑动滚动事件。
    /// - Parameters:
    ///   - isPositiveStep: 硬件正向步进（对 `Scroll` 为向上拨 `0x49`，对 `Knob` 为顺时针 `0x44`）。
    ///   - config: 滚动模式、方向、灵敏度与加速配置。
    ///   - timestamp: 硬件事件时间戳（用于动态连滚加速计算）。
    @discardableResult
    public func sendMouseScroll(
        isPositiveStep: Bool,
        config: MouseScrollConfig,
        timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime,
        promptIfUntrusted: Bool = true
    ) -> Bool {
        guard isAccessibilityTrusted(prompt: promptIfUntrusted) else {
            return false
        }

        var accelMultiplier: Double = 1.0
        if config.dynamicAcceleration {
            if let prevTime = lastScrollTimestamp,
               let prevPos = lastScrollPositive,
               prevPos == isPositiveStep
            {
                let dt = max(0, timestamp - prevTime)
                if dt < 0.045 {
                    accelMultiplier = 2.4
                } else if dt < 0.095 {
                    accelMultiplier = 1.55
                }
            }
            lastScrollTimestamp = timestamp
            lastScrollPositive = isPositiveStep
        } else {
            lastScrollTimestamp = nil
            lastScrollPositive = nil
        }

        let effectivePositive = config.invertDirection ? !isPositiveStep : isPositiveStep
        let sign: Int32 = effectivePositive ? 1 : -1
        let clampedSpeed = min(5, max(1, config.speed))

        switch config.mode {
        case .mouseWheelLine:
            let baseLinesTable: [Int] = [1, 2, 3, 5, 8]
            let rawLines = Double(baseLinesTable[clampedSpeed - 1]) * accelMultiplier
            let stepLines = Int32(max(1, Int(rawLines.rounded()))) * sign
            return postScrollCGEvent(units: .line, delta: stepLines, axis: config.axis)

        case .trackpadSmooth:
            let basePixelsTable: [Double] = [28, 46, 68, 96, 136]
            let totalPixels = basePixelsTable[clampedSpeed - 1] * accelMultiplier
            // 拆分为 4 个 120Hz 微帧（权重之和 = 1.0），营造原生触控板丝滑滚动手感
            let weights: [Double] = [0.32, 0.30, 0.23, 0.15]
            let slices: [Int32] = weights.map { w in
                let px = max(1, Int((totalPixels * w).rounded()))
                return Int32(px) * sign
            }

            let ok = postScrollCGEvent(units: .pixel, delta: slices[0], axis: config.axis)
            let axis = config.axis
            Task { @MainActor [weak self] in
                for slice in slices.dropFirst() {
                    try? await Task.sleep(for: .milliseconds(8))
                    guard let self else { return }
                    _ = self.postScrollCGEvent(units: .pixel, delta: slice, axis: axis)
                }
            }
            return ok
        }
    }

    private func postScrollCGEvent(
        units: CGScrollEventUnit,
        delta: Int32,
        axis: MouseScrollConfig.Axis
    ) -> Bool {
        let source = privateEventSource ?? CGEventSource(stateID: .privateState)
        let wheel1: Int32 = (axis == .vertical) ? delta : 0
        let wheel2: Int32 = (axis == .horizontal) ? delta : 0
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: units,
            wheelCount: 2,
            wheel1: wheel1,
            wheel2: wheel2,
            wheel3: 0
        ) else {
            return false
        }
        event.flags = []
        event.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - Mouse Button Click & Hold Synthesis (Middle / Left / Right / Side)

    @discardableResult
    public func sendMouseButtonDown(_ button: MouseClickButton, promptIfUntrusted: Bool = true) -> Bool {
        guard isAccessibilityTrusted(prompt: promptIfUntrusted) else {
            return false
        }
        guard postMouseButtonCGEvent(button, buttonDown: true) else {
            return false
        }
        activeHeldMouseButtons.insert(button)
        return true
    }

    @discardableResult
    public func sendMouseButtonUp(_ button: MouseClickButton) -> Bool {
        activeHeldMouseButtons.remove(button)
        guard isAccessibilityTrusted(prompt: false) else {
            return false
        }
        return postMouseButtonCGEvent(button, buttonDown: false)
    }

    @discardableResult
    public func sendMouseButtonClick(_ button: MouseClickButton, promptIfUntrusted: Bool = true) -> Bool {
        guard isAccessibilityTrusted(prompt: promptIfUntrusted) else {
            return false
        }
        let downOK = postMouseButtonCGEvent(button, buttonDown: true)
        let upOK = postMouseButtonCGEvent(button, buttonDown: false)
        return downOK && upOK
    }

    private func postMouseButtonCGEvent(_ button: MouseClickButton, buttonDown: Bool) -> Bool {
        let source = privateEventSource ?? CGEventSource(stateID: .privateState)
        let cursorPos = CGEvent(source: nil)?.location ?? .zero

        let mouseType: CGEventType
        let cgButton: CGMouseButton
        var customButtonNumber: Int64?

        switch button {
        case .left:
            mouseType = buttonDown ? .leftMouseDown : .leftMouseUp
            cgButton = .left
        case .right:
            mouseType = buttonDown ? .rightMouseDown : .rightMouseUp
            cgButton = .right
        case .middle:
            mouseType = buttonDown ? .otherMouseDown : .otherMouseUp
            cgButton = .center
            customButtonNumber = 2
        case .back:
            mouseType = buttonDown ? .otherMouseDown : .otherMouseUp
            cgButton = .center
            customButtonNumber = 3
        case .forward:
            mouseType = buttonDown ? .otherMouseDown : .otherMouseUp
            cgButton = .center
            customButtonNumber = 4
        }

        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: mouseType,
            mouseCursorPosition: cursorPos,
            mouseButton: cgButton
        ) else {
            return false
        }
        if let customButtonNumber {
            event.setIntegerValueField(.mouseEventButtonNumber, value: customButtonNumber)
        }
        if buttonDown {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        event.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - System Media Keys (NX_SYSDEFINED Subtype 8)

    /// 发送系统媒体键按下或抬起事件。
    public func sendMediaKey(_ action: MediaKeyAction, down: Bool) {
        let keyType = action.nxKeyType
        let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
        let data1 = (keyType << 16) | ((down ? 0xA : 0xB) << 8)
        NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        )?.cgEvent?.post(tap: .cghidEventTap)
    }

    /// 触发一次完整的系统媒体键点按（按下 + 释放）。
    public func triggerMediaKey(_ action: MediaKeyAction) {
        sendMediaKey(action, down: true)
        sendMediaKey(action, down: false)
    }

    // MARK: - Lightweight Shell & AppleScript Execution

    /// 在后台线程异步执行轻量 Shell 命令（`/bin/zsh -c`），绝不阻塞主线程 UI。
    @discardableResult
    public func runShellCommand(_ command: String) async -> ScriptExecutionResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ScriptExecutionResult(succeeded: true)
        }

        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", trimmed]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
                process.waitUntilExit()

                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let stderr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let status = process.terminationStatus

                return ScriptExecutionResult(
                    succeeded: status == 0,
                    exitCode: status,
                    output: stdout,
                    errorMessage: status == 0 ? nil : (stderr.isEmpty ? "Exit code \(status)" : stderr)
                )
            } catch {
                return ScriptExecutionResult(
                    succeeded: false,
                    exitCode: -1,
                    output: "",
                    errorMessage: error.localizedDescription
                )
            }
        }.value
    }

    /// 非阻塞即发即忘（Fire-and-Forget）启动轻量 Shell 命令。
    public func executeShellCommandAsync(_ command: String) {
        Task { [weak self] in
            _ = await self?.runShellCommand(command)
        }
    }

    /// 异步执行轻量 AppleScript（`NSAppleScript`）。
    @discardableResult
    public func runAppleScript(_ source: String) async -> ScriptExecutionResult {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ScriptExecutionResult(succeeded: true)
        }

        return await Task.detached(priority: .userInitiated) {
            var errorDict: NSDictionary?
            guard let script = NSAppleScript(source: trimmed) else {
                return ScriptExecutionResult(
                    succeeded: false,
                    exitCode: -1,
                    output: "",
                    errorMessage: "无法初始化 NSAppleScript"
                )
            }
            let descriptor = script.executeAndReturnError(&errorDict)
            if let errorDict {
                let msg = (errorDict[NSAppleScript.errorMessage] as? String) ?? "\(errorDict)"
                let code = (errorDict[NSAppleScript.errorNumber] as? Int32) ?? -1
                return ScriptExecutionResult(
                    succeeded: false,
                    exitCode: code,
                    output: "",
                    errorMessage: msg
                )
            }
            return ScriptExecutionResult(
                succeeded: true,
                exitCode: 0,
                output: descriptor.stringValue ?? "",
                errorMessage: nil
            )
        }.value
    }

    /// 非阻塞即发即忘执行轻量 AppleScript。
    public func executeAppleScriptAsync(_ source: String) {
        Task { [weak self] in
            _ = await self?.runAppleScript(source)
        }
    }
}
