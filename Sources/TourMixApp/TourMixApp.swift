import AppKit
import Observation
import SwiftUI
import TourMixCore

@main
@MainActor
enum TourMixMain {
    private static var retainedDelegate: TourMixAppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = TourMixAppDelegate()
        retainedDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class TourMixAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private struct StatusBarRenderState: Equatable {
        let bothOnline: Bool
        let anyOnline: Bool
        let dbText: String?
    }

    private var engine: CoordinatorEngine!
    private var launchManager: LaunchAtLoginManager!
    private var hudController: HUDPanelController!
    private var keymapperController: KeymapperWindowController!

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var lastStatusBarRenderState: StatusBarRenderState?

    private lazy var onlineSymbolImage: NSImage? = Self.makeTemplateSymbolImage(named: "dial.medium.fill")
    private lazy var offlineSymbolImage: NSImage? = Self.makeTemplateSymbolImage(named: "dial.medium")

    private static func makeTemplateSymbolImage(named symbolName: String) -> NSImage? {
        guard let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: "TourMix") else {
            return nil
        }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let configured = baseImage.withSymbolConfiguration(config) ?? baseImage
        configured.isTemplate = true
        return configured
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let appIcon = NSImage(contentsOf: iconURL)
        {
            NSApp.applicationIconImage = appIcon
        }

        let engine = CoordinatorEngine()
        let launchManager = LaunchAtLoginManager()
        let hudController = HUDPanelController()
        let keymapperController = KeymapperWindowController(
            engine: engine,
            launchManager: launchManager
        )

        self.engine = engine
        self.launchManager = launchManager
        self.hudController = hudController
        self.keymapperController = keymapperController

        setupPopover()
        setupStatusItem()
        wireEngineCallbacks()

        observeStatusBarState()
        engine.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hudController?.dismissImmediately()
        engine?.stop()
    }

    // MARK: - Status Bar & Transient Popover

    private func setupPopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
    }

    private func makePopoverHostingController() -> NSViewController {
        let popoverRoot = MenuBarPopoverView(
            engine: engine,
            launchManager: launchManager,
            onOpenKeymapper: { [weak self] in
                self?.openKeymapper(tab: .bindings)
            },
            onOpenDiagnostics: { [weak self] in
                self?.openKeymapper(tab: .diagnostics)
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )
        return NSHostingController(rootView: popoverRoot)
    }

    func popoverDidClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.popover.isShown else { return }
            self.popover.contentViewController = nil
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = item

        if let button = item.button {
            button.target = self
            button.action = #selector(handleStatusItemAction(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.toolTip = "TourMix · TourBox Lite × RME Fireface UCX"
        }
    }

    private func wireEngineCallbacks() {
        engine.onHUDEvent = { [weak self] event in
            guard let self, self.engine.configuration.showHUD else { return }
            self.hudController.show(
                HUDPayload(
                    title: event.title,
                    subtitle: event.subtitle,
                    dbText: event.dbText,
                    normalizedLevel: event.normalizedLevel,
                    unityNormalizedPosition: event.unityNormalizedPosition,
                    safetyLimitNormalizedPosition: event.safetyLimitNormalizedPosition,
                    isMuted: event.isMuted,
                    hitZeroDbLock: event.hitZeroDbLock,
                    badgeText: event.badgeText,
                    systemIcon: event.systemIcon
                )
            )
        }

        engine.onOpenKeymapperRequested = { [weak self] in
            self?.openKeymapper(tab: .bindings)
        }
    }

    private func observeStatusBarState() {
        withObservationTracking {
            updateStatusItemAppearance()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeStatusBarState()
            }
        }
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem?.button else { return }

        let bothOnline = engine.tourBoxState.isConnected && engine.totalMix.isConnected
        let anyOnline = engine.tourBoxState.isConnected || engine.totalMix.isConnected
        let dbText = engine.menuBarStatusDbText

        let nextState = StatusBarRenderState(
            bothOnline: bothOnline,
            anyOnline: anyOnline,
            dbText: dbText
        )
        guard nextState != lastStatusBarRenderState else { return }
        lastStatusBarRenderState = nextState

        button.image = bothOnline ? onlineSymbolImage : offlineSymbolImage
        button.alphaValue = anyOnline ? 1.0 : 0.78

        if let dbText {
            let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .baselineOffset: -0.5
            ]
            button.attributedTitle = NSAttributedString(string: " \(dbText)", attributes: attrs)
        } else {
            button.title = ""
        }
    }

    @objc
    private func handleStatusItemAction(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            togglePopover(relativeTo: sender)
            return
        }

        let isRightClick = (event.type == .rightMouseUp)
        let isOptionClick = event.modifierFlags.contains(.option)

        if isRightClick || isOptionClick {
            if popover.isShown {
                popover.performClose(sender)
            }
            showContextMenu(on: sender)
        } else {
            togglePopover(relativeTo: sender)
        }
    }

    private func togglePopover(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(button)
        } else {
            launchManager.refresh()
            if popover.contentViewController == nil {
                popover.contentViewController = makePopoverHostingController()
            }
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showContextMenu(on button: NSStatusBarButton) {
        let menu = NSMenu()

        let statusTitle = "TourBox: \(engine.tourBoxState.isConnected ? "已连接" : "待连接") · TotalMix: \(engine.totalMix.isConnected ? "在线" : "离线")"
        let statusEntry = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusEntry.isEnabled = false
        menu.addItem(statusEntry)
        menu.addItem(.separator())

        let openMapper = NSMenuItem(
            title: "按键映射工作台…",
            action: #selector(openBindingsFromMenu),
            keyEquivalent: ","
        )
        openMapper.target = self
        menu.addItem(openMapper)

        let openDiag = NSMenuItem(
            title: "连接与报文诊断…",
            action: #selector(openDiagnosticsFromMenu),
            keyEquivalent: "d"
        )
        openDiag.target = self
        menu.addItem(openDiag)

        let toggleTM = NSMenuItem(
            title: "显示 / 隐藏 TotalMix 窗口",
            action: #selector(toggleTotalMixFromMenu),
            keyEquivalent: ""
        )
        toggleTM.target = self
        menu.addItem(toggleTM)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出 TourMix",
            action: #selector(quitFromMenu),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.height + 4),
            in: button
        )
    }

    private func openKeymapper(tab: KeymapperTab) {
        keymapperController.showWindow(tab: tab, closingPopover: popover)
    }

    @objc private func openBindingsFromMenu() {
        openKeymapper(tab: .bindings)
    }

    @objc private func openDiagnosticsFromMenu() {
        openKeymapper(tab: .diagnostics)
    }

    @objc private func toggleTotalMixFromMenu() {
        _ = engine.totalMix.toggleTotalMixWindow()
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }
}
