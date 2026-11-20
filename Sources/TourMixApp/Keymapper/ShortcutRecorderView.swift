import AppKit
import SwiftUI
#if canImport(TourMixCore)
import TourMixCore
#endif

/// Native macOS keyboard shortcut recorder capsule (`#5` Major-1).
///
/// - Installs `NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged])` ONLY while actively recording,
///   returning `nil` to swallow shortcuts such as `Cmd+W` / `Cmd+Q` so they never close the keymapper window or quit the app.
/// - `Esc` (`keyCode == 53`) cancels recording; unmodified `Delete` (`keyCode == 51` / `117`) clears the shortcut.
/// - Automatically tears down the monitor on window resign-key, app resign-active, `.onDisappear`, or explicit broadcast.
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
        placeholder: String = "点击录制快捷键…",
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
        placeholder: String = "点击录制快捷键…",
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
                    Image(systemName: isRecording ? "record.circle.fill" : "command")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(
                            isRecording
                                ? Color(red: 1.0, green: 0.45, blue: 0.36)
                                : (resolvedLabel != nil ? Color.accentColor : Color.secondary)
                        )

                    Text(buttonTitle(resolvedLabel: resolvedLabel))
                        .font(.system(size: 12, weight: resolvedLabel != nil || isRecording ? .semibold : .regular, design: .rounded))
                        .foregroundStyle(resolvedLabel != nil || isRecording ? Color.primary : Color.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if isRecording {
                        Text("Esc 取消")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(minWidth: 168)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            isRecording
                                ? Color.accentColor.opacity(0.14)
                                : Color(nsColor: .controlBackgroundColor)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isRecording
                                ? Color.accentColor
                                : Color.primary.opacity(0.16),
                            lineWidth: isRecording ? 1.4 : 0.9
                        )
                )
            }
            .buttonStyle(.plain)

            if keyCode != nil && !isRecording {
                Button {
                    onClear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.plain)
                .help("清空快捷键")
            }
        }
        .onDisappear {
            stopRecording()
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
                return "\(liveModifierPreview)…"
            }
            return "请按下组合键…"
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
            onDeleteClear: {
                onClear()
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

    private static let virtualKeyTable: [UInt16: String] = [
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
        0x52: "KP0", 0x53: "KP1", 0x54: "KP2", 0x55: "KP3", 0x56: "KP4",
        0x57: "KP5", 0x58: "KP6", 0x59: "KP7", 0x5B: "KP8", 0x5C: "KP9",
        0x41: "KP.", 0x43: "KP*", 0x45: "KP+", 0x47: "Clear", 0x4B: "KP/", 0x4E: "KP-"
    ]
}

// MARK: - Local Event Monitor Lifecycle Controller

@MainActor
private final class ShortcutEventMonitorController {
    private var eventMonitor: Any?
    private var notificationTokens: [NSObjectProtocol] = []
    private var cancelHandler: (() -> Void)?

    private static let modifierOnlyKeyCodes: Set<UInt16> = [
        54, 55, // Right/Left Command
        56, 60, // Left/Right Shift
        57,     // Caps Lock
        58, 61, // Left/Right Option
        59, 62, // Left/Right Control
        63      // Function (Fn)
    ]

    func start(
        onModifiersChanged: @escaping (String) -> Void,
        onCancel: @escaping () -> Void,
        onDeleteClear: @escaping () -> Void,
        onCaptured: @escaping (UInt16, Bool, Bool, Bool, Bool, String) -> Void
    ) {
        stop()
        self.cancelHandler = onCancel

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let ctrl = flags.contains(.control)
            let opt = flags.contains(.option)
            let shft = flags.contains(.shift)
            let cmd = flags.contains(.command)
            let hasAnyMod = ctrl || opt || shft || cmd

            if event.type == .flagsChanged {
                var prefix = ""
                if ctrl { prefix += "⌃" }
                if opt { prefix += "⌥" }
                if shft { prefix += "⇧" }
                if cmd { prefix += "⌘" }
                onModifiersChanged(prefix)
                return nil
            }

            guard event.type == .keyDown else {
                return event
            }

            let code = event.keyCode
            if Self.modifierOnlyKeyCodes.contains(code) {
                return nil
            }

            // Esc (53) without modifiers cancels recording without closing window
            if code == 53 && !hasAnyMod {
                onCancel()
                return nil
            }

            // Delete (51) or Forward Delete (117) without modifiers clears shortcut
            if (code == 51 || code == 117) && !hasAnyMod {
                onDeleteClear()
                return nil
            }

            let label = ShortcutRecorderView.formatShortcut(
                keyCode: code,
                control: ctrl,
                option: opt,
                shift: shft,
                command: cmd,
                fallbackCharacters: event.charactersIgnoringModifiers
            )
            onCaptured(code, ctrl, opt, shft, cmd, label)
            // Swallow event so shortcuts like Cmd+W or Cmd+Q never close window or quit app
            return nil
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

    func stop() {
        cancelHandler = nil
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
