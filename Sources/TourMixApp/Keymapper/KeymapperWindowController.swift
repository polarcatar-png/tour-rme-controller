import AppKit
import Observation
import SwiftUI
import TourMixCore

@MainActor
@Observable
private final class KeymapperWindowState {
    var selectedTab: KeymapperTab = .bindings
}

/// Reusable single-window controller for the TourMix Keymapper & Diagnostics workbench (`#5` Major-1).
///
/// Elevates `NSApp` activation policy to `.regular` when opening so the window reliably becomes Key Window
/// above fullscreen/DAW apps and receives keyboard input, then restores `.accessory` on close so no Dock icon
/// or ghost window lingers.
@MainActor
public final class KeymapperWindowController: NSObject, NSWindowDelegate {
    private let engine: CoordinatorEngine
    private let launchManager: LaunchAtLoginManager
    private let windowState = KeymapperWindowState()
    private var window: NSWindow?

    public init(engine: CoordinatorEngine, launchManager: LaunchAtLoginManager) {
        self.engine = engine
        self.launchManager = launchManager
        super.init()
    }

    public func showWindow(tab: KeymapperTab = .bindings, closingPopover: NSPopover? = nil) {
        if let popover = closingPopover, popover.isShown {
            popover.performClose(nil)
        }

        windowState.selectedTab = tab
        let targetWindow = ensureWindow()

        NSApp.setActivationPolicy(.regular)
        targetWindow.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    public func closeWindow() {
        window?.close()
    }

    // MARK: - NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.post(
            name: ShortcutRecorderView.cancelRecordingNotification,
            object: nil
        )

        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Private Window Construction

    private func ensureWindow() -> NSWindow {
        if let existing = window {
            return existing
        }

        let rootView = KeymapperWindowHostView(
            engine: engine,
            launchManager: launchManager,
            state: windowState
        )
        let hostingController = NSHostingController(rootView: rootView)

        let created = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 630),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        created.contentViewController = hostingController
        created.title = "TourMix 控制台"
        created.titlebarAppearsTransparent = false
        created.isReleasedWhenClosed = false
        created.minSize = NSSize(width: 860, height: 560)
        created.appearance = NSAppearance(named: .darkAqua)
        created.delegate = self
        created.center()

        self.window = created
        return created
    }
}

private struct KeymapperWindowHostView: View {
    let engine: CoordinatorEngine
    let launchManager: LaunchAtLoginManager
    @Bindable var state: KeymapperWindowState

    var body: some View {
        KeymapperWindowView(
            engine: engine,
            launchManager: launchManager,
            selectedTab: $state.selectedTab
        )
    }
}
