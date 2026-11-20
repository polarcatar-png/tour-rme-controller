import AppKit
import SwiftUI

/// Non-activating fullscreen-capable HUD panel controller (`#5` Critical-1 & Major-2).
///
/// - Reuses a single fixed-size `300 x 84` `NSPanel` (`.nonactivatingPanel` + `.fullScreenAuxiliary`)
/// - Never steals Key Window or switches Spaces out of fullscreen DAW / video apps
/// - Positions onto the screen currently containing the mouse cursor (`visibleFrame.minY + 72 pt`)
/// - Uses monotonic `fadeGeneration: UInt64` + cancellable `1.2 s` `Task` to eliminate mid-fade flicker
@MainActor
public final class HUDPanelController {
    public static let panelSize = NSSize(width: 300, height: 84)
    public static let bottomOffset: CGFloat = 72

    private let viewModel = HUDViewModel()
    private let panel: NSPanel
    private var fadeGeneration: UInt64 = 0
    private var fadeTask: Task<Void, Never>?

    /// Hold duration in milliseconds before starting alpha fade-out. Default: `1200` ms.
    public var holdDurationMs: Int = 1200

    public init() {
        let contentRect = NSRect(origin: .zero, size: Self.panelSize)
        let hudPanel = NSPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        hudPanel.level = .statusBar
        hudPanel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        hudPanel.hidesOnDeactivate = false
        hudPanel.isFloatingPanel = true
        hudPanel.becomesKeyOnlyIfNeeded = true
        hudPanel.isOpaque = false
        hudPanel.backgroundColor = .clear
        hudPanel.hasShadow = true
        hudPanel.ignoresMouseEvents = true
        hudPanel.animationBehavior = .none

        let hostingView = NSHostingView(rootView: HUDContentView(model: viewModel))
        hostingView.frame = NSRect(origin: .zero, size: Self.panelSize)
        hudPanel.contentView = hostingView

        self.panel = hudPanel
    }

    /// Displays or updates the HUD immediately on the active cursor screen and resets the `1.2 s` auto-hide timer.
    public func show(_ payload: HUDPayload) {
        fadeGeneration &+= 1
        let generation = fadeGeneration
        fadeTask?.cancel()

        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            viewModel.payload = payload
        }

        positionPanelIfNeeded()

        // Immediately cancel any in-flight AppKit alpha animation and restore full opacity
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1.0
        }
        panel.alphaValue = 1.0

        if !panel.isVisible {
            panel.orderFrontRegardless()
        }

        let holdMs = max(150, holdDurationMs)
        fadeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(holdMs))
            guard !Task.isCancelled, let self, self.fadeGeneration == generation else { return }

            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.panel.animator().alphaValue = 0.0
            }, completionHandler: nil)

            try? await Task.sleep(for: .milliseconds(190))
            guard !Task.isCancelled, self.fadeGeneration == generation else { return }
            self.panel.orderOut(nil)
        }
    }

    /// Immediately hides the HUD panel and cancels pending fade tasks.
    public func dismissImmediately() {
        fadeGeneration &+= 1
        fadeTask?.cancel()
        fadeTask = nil
        panel.alphaValue = 0.0
        panel.orderOut(nil)
    }

    // MARK: - Multi-Monitor Positioning

    private func positionPanelIfNeeded() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first

        guard let screen else { return }

        let visible = screen.visibleFrame
        let targetOrigin = NSPoint(
            x: round(visible.midX - Self.panelSize.width * 0.5),
            y: round(visible.minY + Self.bottomOffset)
        )

        // Avoid redundant WindowServer frame IPC during 30~80 Hz rotary bursts on the same monitor
        let currentOrigin = panel.frame.origin
        if !panel.isVisible
            || abs(currentOrigin.x - targetOrigin.x) > 0.5
            || abs(currentOrigin.y - targetOrigin.y) > 0.5
        {
            panel.setFrameOrigin(targetOrigin)
        }
    }
}
