import AppKit
import SwiftUI

private final class TextCommandKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    var onEscape: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        // Escape must still work when the input is disabled or has lost focus.
        if event.type == .keyDown, event.keyCode == 53 {
            onEscape?()
            return
        }
        super.sendEvent(event)
    }
}

@MainActor
final class TextCommandPanelManager {
    private weak var companionManager: CompanionManager?
    private var panel: NSPanel?
    private var mouseTrackingTimer: Timer?
    private var currentPanelOrigin: CGPoint?

    // Grows when the Jev loop has results to draw under the input. Every
    // consumer reads this property, and positionPanel re-asserts the frame at
    // 60Hz, so changing it here is enough to resize the live window.
    static let baseHeight: CGFloat = 96
    private var panelSize = NSSize(width: 440, height: TextCommandPanelManager.baseHeight)
    private var isTrackingFrozen = false
    private let screenEdgeInset: CGFloat = 12
    private let cursorClearance: CGFloat = 44
    private let horizontalOffsetFromCursor: CGFloat = 56
    private let verticalOffsetFromCursor: CGFloat = 32
    private let trackingInterval: TimeInterval = 1.0 / 60.0
    private let smoothingFactor: CGFloat = 0.24
    private let fadeDuration: TimeInterval = 0.12

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    func show() {
        guard let companionManager else { return }

        if panel == nil {
            createPanel(companionManager: companionManager)
        }

        let mouseLocation = NSEvent.mouseLocation
        currentPanelOrigin = nil

        panel?.alphaValue = 0
        positionPanel(at: mouseLocation, animated: false)
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        fadePanel(to: 1)
        startMouseTracking()
    }

    func hide() {
        panel?.orderOut(nil)
        stopMouseTracking()
    }

    private func createPanel(companionManager: CompanionManager) {
        // No outer .frame here: the view sizes itself (TextCommandPanelView's
        // own .frame reads panelHeight) so it can grow when the Jev loop has
        // results to show. The window frame is driven by setResultsHeight.
        let textCommandView = TextCommandPanelView(companionManager: companionManager)

        let hostingView = NSHostingView(rootView: textCommandView)
        hostingView.frame = NSRect(origin: .zero, size: panelSize)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        hostingView.sizingOptions = []

        let commandPanel = TextCommandKeyablePanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        commandPanel.onEscape = { [weak companionManager] in
            companionManager?.dismissTextCommandPanel()
        }
        commandPanel.appearance = NSAppearance(named: .aqua)
        commandPanel.isFloatingPanel = true
        commandPanel.level = .floating
        commandPanel.isOpaque = false
        commandPanel.backgroundColor = .clear
        commandPanel.hasShadow = false
        commandPanel.hidesOnDeactivate = false
        commandPanel.isExcludedFromWindowsMenu = true
        commandPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        commandPanel.isMovableByWindowBackground = false
        commandPanel.titleVisibility = .hidden
        commandPanel.titlebarAppearsTransparent = true
        commandPanel.contentView = hostingView

        panel = commandPanel
    }

    private func startMouseTracking() {
        stopMouseTracking()
        let trackingTimer = Timer(timeInterval: trackingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMouseTrackingTick()
            }
        }
        mouseTrackingTimer = trackingTimer
        RunLoop.main.add(trackingTimer, forMode: .common)
    }

    private func stopMouseTracking() {
        mouseTrackingTimer?.invalidate()
        mouseTrackingTimer = nil
        currentPanelOrigin = nil
    }

    /// While the loop is driving the pointer, the panel must stop chasing it —
    /// otherwise it flies across the screen mid-run and lands inside the very
    /// screenshot the next detection pass reads.
    func setTrackingFrozen(_ frozen: Bool) {
        isTrackingFrozen = frozen
        if frozen {
            mouseTrackingTimer?.invalidate()
            mouseTrackingTimer = nil
        } else if panel?.isVisible == true {
            startMouseTracking()
        }
    }

    /// Resize the live panel to fit `extraHeight` of results under the input.
    func setResultsHeight(_ extraHeight: CGFloat) {
        let height = TextCommandPanelManager.baseHeight + max(0, extraHeight)
        guard abs(panelSize.height - height) > 0.5 else { return }
        panelSize = NSSize(width: panelSize.width, height: height)
        if let panel {
            // The hosting view is generic over the wrapped root view type, so
            // resize it as a plain NSView rather than casting.
            panel.contentView?.frame = NSRect(origin: .zero, size: panelSize)
            if isTrackingFrozen {
                let visibleFrame = panel.screen?.visibleFrame ?? panel.frame
                let origin = CGPoint(
                    x: min(max(panel.frame.minX, visibleFrame.minX), visibleFrame.maxX - panelSize.width),
                    y: max(visibleFrame.minY, panel.frame.maxY - panelSize.height)
                )
                currentPanelOrigin = origin
                panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
            } else {
                positionPanel(at: NSEvent.mouseLocation, animated: false)
            }
        }
    }

    private func handleMouseTrackingTick() {
        guard let panel, panel.isVisible, !isTrackingFrozen else { return }
        positionPanel(at: NSEvent.mouseLocation, animated: true)
    }

    private func positionPanel(at mouseLocation: CGPoint, animated: Bool) {
        guard let panel else { return }
        let targetScreen = NSScreen.screens.first { screen in
            screen.frame.contains(mouseLocation)
        } ?? NSScreen.main
        guard let screenFrame = targetScreen?.frame else { return }

        let targetOrigin = targetPanelOrigin(
            mouseLocation: mouseLocation,
            panelSize: panelSize,
            screenFrame: screenFrame
        )
        let nextOrigin = smoothedOrigin(
            currentOrigin: currentPanelOrigin,
            targetOrigin: targetOrigin,
            animated: animated
        )
        currentPanelOrigin = nextOrigin

        let currentFrame = panel.frame
        let positionChanged = abs(currentFrame.minX - nextOrigin.x) > 0.35
            || abs(currentFrame.minY - nextOrigin.y) > 0.35
        guard positionChanged || currentFrame.size != panelSize else { return }

        panel.setFrame(
            NSRect(x: nextOrigin.x, y: nextOrigin.y, width: panelSize.width, height: panelSize.height),
            display: true,
            animate: false
        )
    }

    private func targetPanelOrigin(
        mouseLocation: CGPoint,
        panelSize: NSSize,
        screenFrame: CGRect
    ) -> CGPoint {
        let candidateOrigins = [
            CGPoint(
                x: mouseLocation.x + horizontalOffsetFromCursor,
                y: mouseLocation.y - panelSize.height - verticalOffsetFromCursor
            ),
            CGPoint(
                x: mouseLocation.x + horizontalOffsetFromCursor,
                y: mouseLocation.y + verticalOffsetFromCursor
            ),
            CGPoint(
                x: mouseLocation.x - panelSize.width - horizontalOffsetFromCursor,
                y: mouseLocation.y - panelSize.height - verticalOffsetFromCursor
            ),
            CGPoint(
                x: mouseLocation.x - panelSize.width - horizontalOffsetFromCursor,
                y: mouseLocation.y + verticalOffsetFromCursor
            )
        ]

        let cursorSafetyRect = CGRect(
            x: mouseLocation.x - cursorClearance,
            y: mouseLocation.y - cursorClearance,
            width: cursorClearance * 2,
            height: cursorClearance * 2
        )

        let preferredOrigin = candidateOrigins.first { candidateOrigin in
            let panelRect = CGRect(origin: candidateOrigin, size: panelSize)
            return screenFrame.contains(panelRect) && !panelRect.intersects(cursorSafetyRect)
        } ?? candidateOrigins[0]

        return CGPoint(
            x: min(
                max(preferredOrigin.x, screenFrame.minX + screenEdgeInset),
                screenFrame.maxX - panelSize.width - screenEdgeInset
            ),
            y: min(
                max(preferredOrigin.y, screenFrame.minY + screenEdgeInset),
                screenFrame.maxY - panelSize.height - screenEdgeInset
            )
        )
    }

    private func smoothedOrigin(
        currentOrigin: CGPoint?,
        targetOrigin: CGPoint,
        animated: Bool
    ) -> CGPoint {
        guard animated, let currentOrigin else { return targetOrigin }

        let deltaX = targetOrigin.x - currentOrigin.x
        let deltaY = targetOrigin.y - currentOrigin.y
        if abs(deltaX) < 0.5, abs(deltaY) < 0.5 {
            return targetOrigin
        }

        return CGPoint(
            x: currentOrigin.x + deltaX * smoothingFactor,
            y: currentOrigin.y + deltaY * smoothingFactor
        )
    }

    private func fadePanel(to alphaValue: CGFloat) {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = alphaValue
        }
    }
}
