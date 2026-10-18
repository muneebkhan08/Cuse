//
//  MenuBarPanelManager.swift
//  Cuse
//
//  Owns the menu bar status item and delegates panel mechanics to
//  FloatingCompanionPanel.
//

import AppKit

extension Notification.Name {
    static let cuseDismissPanel = Notification.Name("cuseDismissPanel")
    static let cuseOpenSettings = Notification.Name("cuseOpenSettings")
    static let cuseOpenLogs = Notification.Name("cuseOpenLogs")
    static let cusePanelPinStateChanged = Notification.Name("cusePanelPinStateChanged")
    static let cuseUserInterfaceActionExecuted = Notification.Name("cuseUserInterfaceActionExecuted")
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: FloatingCompanionPanel<CompanionPanelView>?
    private var settingsWindowManager: CuseSettingsWindowManager?
    private var logsWindowManager: CuseLogsWindowManager?
    private var dismissPanelObserver: NSObjectProtocol?
    private var openSettingsObserver: NSObjectProtocol?
    private var openLogsObserver: NSObjectProtocol?
    private var pinStateChangedObserver: NSObjectProtocol?

    private let companionManager: CompanionManager
    private let panelWidth: CGFloat = 400
    private let panelHeight: CGFloat = 380

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        settingsWindowManager = CuseSettingsWindowManager(companionManager: companionManager)
        logsWindowManager = CuseLogsWindowManager()
        createStatusItem()
        installPanelObservers()
    }

    deinit {
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = openSettingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = openLogsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = pinStateChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Status Item

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // A stable name lets macOS remember the item's position, and forcing
        // isVisible overrides a stale "hidden" flag left by an earlier
        // Command-drag removal from the menu bar.
        statusItem?.autosaveName = "CuseStatusItem"
        statusItem?.isVisible = true

        guard let button = statusItem?.button else { return }

        button.image = makeMenuBarIcon()
        button.image?.isTemplate = true
        button.toolTip = "Cuse"
        button.setAccessibilityLabel("Cuse")
        button.action = #selector(statusItemClicked)
        button.target = self
        // Right-click opens a small menu, left-click toggles the panel.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// With a crowded menu bar or a notch, macOS can push the icon out of
    /// sight. If the icon is not actually on screen shortly after launch, open
    /// the panel so Cuse is still reachable.
    func showPanelIfMenuBarIconIsHidden() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard !self.isStatusItemOnScreen else { return }
            self.showPanel()
        }
    }

    /// Opens the panel when the app is launched again from Finder or Spotlight.
    func showPanelForReopen() {
        showPanel()
    }

    private var isStatusItemOnScreen: Bool {
        guard let buttonWindow = statusItem?.button?.window else { return false }
        return NSScreen.screens.contains { $0.frame.intersects(buttonWindow.frame) }
            && buttonWindow.occlusionState.contains(.visible)
    }

    private func showStatusItemContextMenu() {
        let contextMenu = NSMenu()
        contextMenu.addItem(withTitle: "Open Cuse", action: #selector(openPanelFromMenu), keyEquivalent: "").target = self
        contextMenu.addItem(withTitle: "Settings", action: #selector(openSettingsFromMenu), keyEquivalent: "").target = self
        contextMenu.addItem(withTitle: "Logs", action: #selector(openLogsFromMenu), keyEquivalent: "").target = self
        contextMenu.addItem(.separator())
        contextMenu.addItem(withTitle: "Quit Cuse", action: #selector(quitFromMenu), keyEquivalent: "q").target = self
        statusItem?.menu = contextMenu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func openPanelFromMenu() { showPanel() }
    @objc private func openSettingsFromMenu() { settingsWindowManager?.show() }
    @objc private func openLogsFromMenu() { logsWindowManager?.show() }
    @objc private func quitFromMenu() { NSApp.terminate(nil) }

    /// Draws the same pointer silhouette used by the overlay cursor.
    private func makeMenuBarIcon() -> NSImage {
        let iconSize: CGFloat = 18
        let image = NSImage(size: NSSize(width: iconSize, height: iconSize))
        image.lockFocus()

        let viewBoxSize: CGFloat = 24
        let scale = iconSize * 0.92 / viewBoxSize
        let originX = iconSize * 0.5 - viewBoxSize * scale * 0.5
        let originY = iconSize * 0.5 - viewBoxSize * scale * 0.5

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: originX + x * scale,
                y: originY + (viewBoxSize - y) * scale
            )
        }

        let path = NSBezierPath()
        path.move(to: point(3.2, 3.2))
        path.line(to: point(16.4, 9.6))
        path.line(to: point(11.2, 11.2))
        path.line(to: point(9.6, 16.4))
        path.close()

        NSColor.black.setFill()
        path.fill()

        image.unlockFocus()
        return image
    }

    /// Opens the panel automatically on app launch so the user sees
    /// permissions and the start button right away.
    func showPanelOnLaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showPanel()
        }
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusItemContextMenu()
            return
        }
        if panel?.isPresented == true {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: - Panel Lifecycle

    private func showPanel() {
        if panel == nil {
            createPanel()
        }

        panel?.showAnchoredToStatusItem()
    }

    private func hidePanel() {
        panel?.hide()
    }

    private func createPanel() {
        panel = FloatingCompanionPanel(
            width: panelWidth,
            initialHeight: panelHeight,
            statusBarButton: statusItem?.button,
            isPinnedProvider: { [weak companionManager] in
                companionManager?.isPanelPinned ?? false
            },
            shouldDeferOutsideClickDismissal: { [weak companionManager] in
                guard let companionManager else { return false }
                return !companionManager.allPermissionsGranted && !NSApp.isActive
            }
        ) {
            CompanionPanelView(companionManager: companionManager)
        }
    }

    private func installPanelObservers() {
        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .cuseDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.hidePanel()
            }
        }

        openSettingsObserver = NotificationCenter.default.addObserver(
            forName: .cuseOpenSettings,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.settingsWindowManager?.show()
            }
        }

        openLogsObserver = NotificationCenter.default.addObserver(
            forName: .cuseOpenLogs,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.logsWindowManager?.show()
            }
        }

        pinStateChangedObserver = NotificationCenter.default.addObserver(
            forName: .cusePanelPinStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.panel?.refreshOutsideClickMonitor()
            }
        }
    }
}
