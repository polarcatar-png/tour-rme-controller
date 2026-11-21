import AppKit
import SwiftUI
#if canImport(TourMixCore)
import TourMixCore
#endif

/// Native macOS single-key & combo shortcut recorder capsule.
///
/// Key engineering guarantees:
/// 1. **Bypasses CJK / Pinyin Input Method (`NSTextInputClient`)**: While recording, moves `NSWindow.firstResponder`
///    away from `NSHostingView` onto a dedicated `ShortcutCaptureNSView` whose `inputContext` is `nil`, deactivating
///    `TSMDocument` so single unmodified keys (`A–Z`, `0–9`, `Space`, punctuation) arrive as raw hardware key events.
/// 2. **Supports EVERY single key**:
///    - Single letters, digits, symbols, `Space`, `Return`, `Tab`, arrows, `F1–F20`;
///    - Single `Delete` (`⌫` / `⌦`) and single `Esc` (`⎋`) directly;
///    - Standalone modifier keys (`⌘ Command`, `⌥ Option`, `⇧ Shift`, `⌃ Control`) via tap-and-release
///      (holding `⇧` + pressing `Z` still records `⇧Z`, whereas tapping & releasing `⇧` alone records `⇧ Shift`!).
/// 3. **Swallows window-closing combos (`⌘W`, `⌘Q`)** during recording and provides a 1-click quick-pick menu.
public struct ShortcutRecorderView: View {
    public typealias RecordHandler = (
        _ keyCode: UInt16,
        _ control: Bool,
        _ option: Bool,
        _ shift: Bool,
        _ command: Bool,
        _ displayLabel: String
    ) -> Void

    /// Post this notification (e.g. from `KeymapperWindowController.windowWillClose`) to cancel any active shortcut recording immediately.
    public static let cancelRecordingNotification = Notification.Name("com.soundlab.TourMix.cancelShortcutRecording")

    public var keyCode: UInt16?
    public var control: Bool
    public var option: Bool
    public var shift: Bool
    public var command: Bool
    public var displayLabel: String
    public var placeholder: String
    public var onRecord: RecordHandler
    public var onClear: () -> Void

    @State private var isRecording = false
    @State private var liveModifierPreview: String = ""
    @State private var monitorController = ShortcutEventMonitorController()

    public init(
        keyCode: UInt16?,
        control: Bool = false,
        option: Bool = false,
        shift: Bool = false,
        command: Bool = false,
        displayLabel: String = "",
        placeholder: String = "点击录制单键或组合键…",
        onRecord: @escaping RecordHandler,
        onClear: @escaping () -> Void
    ) {
        self.keyCode = keyCode
        self.control = control
        self.option = option
        self.shift = shift
        self.command = command
        self.displayLabel = displayLabel
        self.placeholder = placeholder
        self.onRecord = onRecord
        self.onClear = onClear
    }

    #if canImport(TourMixCore)
    /// Convenience initializer binding directly to `TourMixCore.KeyCombo?`.
    public init(
        combo: KeyCombo?,
        placeholder: String = "点击录制单键或组合键…",
        onChange: @escaping (KeyCombo?) -> Void
    ) {
        self.init(
            keyCode: combo?.keyCode,
            control: combo?.control ?? false,
            option: combo?.option ?? false,
            shift: combo?.shift ?? false,
            command: combo?.command ?? false,
            displayLabel: combo?.displayLabel ?? "",
            placeholder: placeholder,
            onRecord: { keyCode, ctrl, opt, shft, cmd, label in
                onChange(
                    KeyCombo(
                        keyCode: keyCode,
                        control: ctrl,
                        option: opt,
                        shift: shft,
                        command: cmd,
                        displayLabel: label
                    )
                )
            },
            onClear: {
                onChange(nil)
            }
        )
    }
    #endif

    public var body: some View {
        let resolvedLabel = effectiveDisplayLabel

        HStack(spacing: 6) {
            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isRecording ? "record.circle.fill" : "keyboard")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(
                            isRecording
                                ? TotalMixTheme.rmeRed
                                : (resolvedLabel != nil ? TotalMixTheme.accent : TotalMixTheme.textSecondary)
                        )

                    Text(buttonTitle(resolvedLabel: resolvedLabel))
                        .font(.system(size: 12, weight: resolvedLabel != nil || isRecording ? .semibold : .regular, design: .rounded))
                        .foregroundStyle(resolvedLabel != nil || isRecording ? TotalMixTheme.textPrimary : TotalMixTheme.textSecondary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if isRecording {
                        Text("点此取消")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(TotalMixTheme.textSecondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(minWidth: 184)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            isRecording
                                ? TotalMixTheme.accentDeep.opacity(0.24)
                                : TotalMixTheme.chassisDeep
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isRecording
                                ? TotalMixTheme.accent
                                : TotalMixTheme.borderSubtle,
                            lineWidth: isRecording ? 1.4 : 0.9
                        )
                )
            }
            .buttonStyle(.plain)
            .background(
                ShortcutFirstResponderBridge(
                    isRecording: isRecording,
                    onKeyEvent: { event in
                        monitorController.processEvent(event)
                    }
                )
                .frame(width: 0, height: 0)
            )

            quickPickMenu

            if keyCode != nil && !isRecording {
                Button {
                    onClear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.plain)
                .help("清空按键")
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    // MARK: - Quick-Pick Single Key Menu

    private var quickPickMenu: some View {
        Menu {
            Section("常用单键") {
                quickPickItem("Space (空格)", keyCode: 0x31)
                quickPickItem("↩ Return (回车)", keyCode: 0x24)
                quickPickItem("⌫ Delete (退格)", keyCode: 0x33)
                quickPickItem("⌦ Forward Delete", keyCode: 0x75)
                quickPickItem("⎋ Esc", keyCode: 0x35)
                quickPickItem("⇥ Tab", keyCode: 0x30)
            }

            Section("方向键") {
                quickPickItem("↑ 向上", keyCode: 0x7E)
                quickPickItem("↓ 向下", keyCode: 0x7D)
                quickPickItem("← 向左", keyCode: 0x7B)
                quickPickItem("→ 向右", keyCode: 0x7C)
            }

            Section("单独修饰键（按住生效）") {
                quickPickItem("⌘ Command", keyCode: 0x37)
                quickPickItem("⌥ Option", keyCode: 0x3A)
                quickPickItem("⇧ Shift", keyCode: 0x38)
                quickPickItem("⌃ Control", keyCode: 0x3B)
            }

            Menu("字母键 A – Z") {
                ForEach(Self.alphabetKeyItems, id: \.code) { item in
                    quickPickItem(item.label, keyCode: item.code)
                }
            }

            Menu("功能键 F1 – F12") {
                ForEach(Self.functionKeyItems, id: \.code) { item in
                    quickPickItem(item.label, keyCode: item.code)
                }
            }
        } label: {
            Image(systemName: "keyboard.chevron.compact.down")
                .font(.system(size: 12))
                .foregroundStyle(TotalMixTheme.textSecondary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(TotalMixTheme.surfaceControl)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(TotalMixTheme.borderSubtle, lineWidth: 0.8)
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("直接从列表选择单个按键")
    }

    private func quickPickItem(_ title: String, keyCode: UInt16) -> some View {
        Button(title) {
            stopRecording()
            let label = Self.formatShortcut(
                keyCode: keyCode,
                control: false,
                option: false,
                shift: false,
                command: false
            )
            onRecord(keyCode, false, false, false, false, label)
        }
    }

    // MARK: - Recording State Control

    private var effectiveDisplayLabel: String? {
        if !displayLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return displayLabel
        }
        guard let keyCode else { return nil }
        return Self.formatShortcut(
            keyCode: keyCode,
            control: control,
            option: option,
            shift: shift,
            command: command
        )
    }

    private func buttonTitle(resolvedLabel: String?) -> String {
        if isRecording {
            if !liveModifierPreview.isEmpty {
                return "\(liveModifierPreview)（松开绑单键 / 续按组合）"
            }
            return "请按任意单键或组合键…"
        }
        return resolvedLabel ?? placeholder
    }

    private func startRecording() {
        liveModifierPreview = ""
        isRecording = true

        monitorController.start(
            onModifiersChanged: { preview in
                liveModifierPreview = preview
            },
            onCancel: {
                stopRecording()
            },
            onCaptured: { capturedKeyCode, ctrl, opt, shft, cmd, label in
                onRecord(capturedKeyCode, ctrl, opt, shft, cmd, label)
                stopRecording()
            }
        )
    }

    private func stopRecording() {
        monitorController.stop()
        isRecording = false
        liveModifierPreview = ""
    }

    // MARK: - macOS Virtual KeyCode Formatter

    public static func formatShortcut(
        keyCode: UInt16,
        control: Bool,
        option: Bool,
        shift: Bool,
        command: Bool,
        fallbackCharacters: String? = nil
    ) -> String {
        if standaloneModifierKeyCodes.contains(keyCode) && !control && !option && !shift && !command {
            return keyGlyph(for: keyCode, fallbackCharacters: fallbackCharacters)
        }
        var parts = ""
        if control { parts += "⌃" }
        if option { parts += "⌥" }
        if shift { parts += "⇧" }
        if command { parts += "⌘" }
        parts += keyGlyph(for: keyCode, fallbackCharacters: fallbackCharacters)
        return parts
    }

    public static func keyGlyph(for keyCode: UInt16, fallbackCharacters: String? = nil) -> String {
        if let mapped = virtualKeyTable[keyCode] {
            return mapped
        }
        if let chars = fallbackCharacters?.trimmingCharacters(in: .whitespacesAndNewlines),
           !chars.isEmpty
        {
            return chars.uppercased()
        }
        return "Key(\(keyCode))"
    }

    fileprivate static let standaloneModifierKeyCodes: Set<UInt16> = [
        0x36, 0x37, // Right/Left Command (54, 55)
        0x38, 0x3C, // Left/Right Shift (56, 60)
        0x39,       // Caps Lock (57)
        0x3A, 0x3D, // Left/Right Option (58, 61)
        0x3B, 0x3E, // Left/Right Control (59, 62)
        0x3F        // Function (63)
    ]

    private static let alphabetKeyItems: [(label: String, code: UInt16)] = [
        ("A", 0x00), ("B", 0x0B), ("C", 0x08), ("D", 0x02), ("E", 0x0E), ("F", 0x03),
        ("G", 0x05), ("H", 0x04), ("I", 0x22), ("J", 0x26), ("K", 0x28), ("L", 0x25),
        ("M", 0x2E), ("N", 0x2D), ("O", 0x1F), ("P", 0x23), ("Q", 0x0C), ("R", 0x0F),
        ("S", 0x01), ("T", 0x11), ("U", 0x20), ("V", 0x09), ("W", 0x0D), ("X", 0x07),
        ("Y", 0x10), ("Z", 0x06)
    ]

    private static let functionKeyItems: [(label: String, code: UInt16)] = [
        ("F1", 0x7A), ("F2", 0x78), ("F3", 0x63), ("F4", 0x76),
        ("F5", 0x60), ("F6", 0x61), ("F7", 0x62), ("F8", 0x64),
        ("F9", 0x65), ("F10", 0x6D), ("F11", 0x67), ("F12", 0x6F)
    ]

    private static let virtualKeyTable: [UInt16: String] = [
        // Standalone Modifiers
        0x37: "⌘ Command", 0x36: "⌘ Right Cmd",
        0x38: "⇧ Shift", 0x3C: "⇧ Right Shift",
        0x3A: "⌥ Option", 0x3D: "⌥ Right Opt",
        0x3B: "⌃ Control", 0x3E: "⌃ Right Ctrl",
        0x39: "⇪ CapsLock", 0x3F: "fn",
        // Letters (ANSI standard virtual key codes)
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z", 0x07: "X",
        0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y",
        0x11: "T", 0x1F: "O", 0x20: "U", 0x22: "I", 0x23: "P", 0x25: "L", 0x26: "J", 0x28: "K",
        0x2D: "N", 0x2E: "M",
        // Digits & punctuation
        0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5", 0x16: "6", 0x1A: "7", 0x1C: "8",
        0x19: "9", 0x1D: "0", 0x1B: "-", 0x18: "=", 0x21: "[", 0x1E: "]", 0x2A: "\\", 0x29: ";",
        0x27: "'", 0x2B: ",", 0x2F: ".", 0x2C: "/", 0x32: "`",
        // Navigation & editing
        0x24: "↩", 0x30: "⇥", 0x31: "Space", 0x33: "⌫", 0x35: "⎋", 0x4C: "⌤", 0x75: "⌦",
        0x73: "↖", 0x77: "↘", 0x74: "⇞", 0x79: "⇟",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
        // Function keys
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
        0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
        0x69: "F13", 0x6B: "F14", 0x71: "F15", 0x6A: "F16", 0x40: "F17", 0x4F: "F18",
        0x50: "F19", 0x5A: "F20",
        // Keypad
        0x51: "KP=", 0x52: "KP0", 0x53: "KP1", 0x54: "KP2", 0x55: "KP3", 0x56: "KP4",
        0x57: "KP5", 0x58: "KP6", 0x59: "KP7", 0x5B: "KP8", 0x5C: "KP9",
        0x41: "KP.", 0x43: "KP*", 0x45: "KP+", 0x47: "Clear", 0x4B: "KP/", 0x4E: "KP-"
    ]
}

// MARK: - AppKit Non-IME First Responder Bridge

private struct ShortcutFirstResponderBridge: NSViewRepresentable {
    let isRecording: Bool
    let onKeyEvent: (NSEvent) -> Bool

    func makeNSView(context: Context) -> ShortcutCaptureNSView {
        let view = ShortcutCaptureNSView()
        view.onKeyEvent = onKeyEvent
        return view
    }

    func updateNSView(_ nsView: ShortcutCaptureNSView, context: Context) {
        nsView.onKeyEvent = onKeyEvent
        nsView.isCapturing = isRecording
        if isRecording {
            // Deactivate NSHostingView's NSTextInputClient session so CJK/Pinyin IME never intercepts single keys.
            NSTextInputContext.current?.discardMarkedText()
            if nsView.window?.firstResponder !== nsView {
                nsView.window?.makeFirstResponder(nsView)
            }
            DispatchQueue.main.async { [weak nsView] in
                guard let nsView, nsView.isCapturing else { return }
                NSTextInputContext.current?.discardMarkedText()
                if nsView.window?.firstResponder !== nsView {
                    nsView.window?.makeFirstResponder(nsView)
                }
            }
        } else if nsView.window?.firstResponder === nsView {
            nsView.window?.makeFirstResponder(nil)
        }
    }
}

@MainActor
private final class ShortcutCaptureNSView: NSView {
    var isCapturing: Bool = false
    var onKeyEvent: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { isCapturing }

    /// Returning `nil` (and NOT conforming to `NSTextInputClient`) instructs macOS Text Services Manager (`TSM`)
    /// to bypass IME composition completely while this responder holds focus, delivering raw single-key `keyDown` events.
    override var inputContext: NSTextInputContext? { nil }

    override func keyDown(with event: NSEvent) {
        if isCapturing, onKeyEvent?(event) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        if isCapturing, onKeyEvent?(event) == true {
            return
        }
        super.flagsChanged(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isCapturing, onKeyEvent?(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Local Event Monitor & Tap-Modifier State Machine

@MainActor
private final class ShortcutEventMonitorController {
    private var eventMonitor: Any?
    private var notificationTokens: [NSObjectProtocol] = []
    private var onModifiersChanged: ((String) -> Void)?
    private var cancelHandler: (() -> Void)?
    private var capturedHandler: ((UInt16, Bool, Bool, Bool, Bool, String) -> Void)?

    private var isActive = false
    private var pendingSingleModifierCode: UInt16?
    private var modifierChordInvalidatedForSingleTap = false

    func start(
        onModifiersChanged: @escaping (String) -> Void,
        onCancel: @escaping () -> Void,
        onCaptured: @escaping (UInt16, Bool, Bool, Bool, Bool, String) -> Void
    ) {
        stop()
        self.isActive = true
        self.onModifiersChanged = onModifiersChanged
        self.cancelHandler = onCancel
        self.capturedHandler = onCaptured
        self.pendingSingleModifierCode = nil
        self.modifierChordInvalidatedForSingleTap = false

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.isActive else { return event }
            if self.processEvent(event) {
                return nil
            }
            return event
        }

        let center = NotificationCenter.default
        let cancelNames: [Notification.Name] = [
            NSWindow.didResignKeyNotification,
            NSApplication.didResignActiveNotification,
            ShortcutRecorderView.cancelRecordingNotification
        ]

        for name in cancelNames {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.cancelHandler?()
                }
            }
            notificationTokens.append(token)
        }
    }

    /// Processes a key or modifier event from either the local monitor or `ShortcutCaptureNSView`.
    /// Returns `true` when consumed while recording.
    @discardableResult
    func processEvent(_ event: NSEvent) -> Bool {
        guard isActive else { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let ctrl = flags.contains(.control)
        let opt = flags.contains(.option)
        let shft = flags.contains(.shift)
        let cmd = flags.contains(.command)
        let activeModifierCount = [ctrl, opt, shft, cmd].filter { $0 }.count

        if event.type == .flagsChanged {
            let code = event.keyCode
            var prefix = ""
            if ctrl { prefix += "⌃" }
            if opt { prefix += "⌥" }
            if shft { prefix += "⇧" }
            if cmd { prefix += "⌘" }

            if activeModifierCount == 1,
               !modifierChordInvalidatedForSingleTap,
               ShortcutRecorderView.standaloneModifierKeyCodes.contains(code)
            {
                pendingSingleModifierCode = code
                onModifiersChanged?(prefix)
                return true
            }

            if activeModifierCount > 1 {
                // Multiple modifiers held together -> wait for a non-modifier key combo
                modifierChordInvalidatedForSingleTap = true
                pendingSingleModifierCode = nil
                onModifiersChanged?(prefix)
                return true
            }

            if activeModifierCount == 0 {
                // All modifiers released: if user tapped & released a single modifier without pressing another key, bind it!
                if let singleModCode = pendingSingleModifierCode, !modifierChordInvalidatedForSingleTap {
                    pendingSingleModifierCode = nil
                    let label = ShortcutRecorderView.formatShortcut(
                        keyCode: singleModCode,
                        control: false,
                        option: false,
                        shift: false,
                        command: false
                    )
                    isActive = false
                    capturedHandler?(singleModCode, false, false, false, false, label)
                    return true
                }
                pendingSingleModifierCode = nil
                modifierChordInvalidatedForSingleTap = false
                onModifiersChanged?("")
                return true
            }

            onModifiersChanged?(prefix)
            return true
        }

        guard event.type == .keyDown else {
            return false
        }

        let code = event.keyCode
        if ShortcutRecorderView.standaloneModifierKeyCodes.contains(code) {
            return true
        }

        modifierChordInvalidatedForSingleTap = true
        pendingSingleModifierCode = nil

        let label = ShortcutRecorderView.formatShortcut(
            keyCode: code,
            control: ctrl,
            option: opt,
            shift: shft,
            command: cmd,
            fallbackCharacters: event.charactersIgnoringModifiers
        )
        isActive = false
        capturedHandler?(code, ctrl, opt, shft, cmd, label)
        return true
    }

    func stop() {
        isActive = false
        pendingSingleModifierCode = nil
        modifierChordInvalidatedForSingleTap = false
        onModifiersChanged = nil
        cancelHandler = nil
        capturedHandler = nil
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        let center = NotificationCenter.default
        for token in notificationTokens {
            center.removeObserver(token)
        }
        notificationTokens.removeAll()
    }
}
