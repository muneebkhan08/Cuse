//
//  FloatingCompanionPanel.swift
//  Cuse
//
//  Reusable NSPanel host for compact SwiftUI companion surfaces.
//

import AppKit
import SwiftUI

@MainActor
final class FloatingCompanionPanel<Content: View>: NSPanel {
    private weak var statusBarButton: NSStatusBarButton?
    private var clickOutsideMonitor: Any?
    private var hostingViewSizeObservation: NSKeyValueObservation?

    private let panelWidth: CGFloat
    private let gapBelowStatusItem: CGFloat
    private let isPinnedProvider: () -> Bool
    private let shouldDeferOutsideClickDismissal: () -> Bool
    private let onClose: () -> Void

    private(set) var isPresented = false

    init(
        width: CGFloat,
        initialHeight: CGFloat,
        statusBarButton: NSStatusBarButton?,
        gapBelowStatusItem: CGFloat = 4,
        isPinnedProvider: @escaping () -> Bool,
        shouldDeferOutsideClickDismissal: @escaping () -> Bool,
        onClose: @escaping () -> Void = {},
        content: () -> Content
    ) {
        self.panelWidth = width
        self.gapBelowStatusItem = gapBelowStatusItem
        self.statusBarButton = statusBarButton
        self.isPinnedProvider = isPinnedProvider
        self.shouldDeferOutsideClickDismissal = shouldDeferOutsideClickDismissal
        self.onClose = onClose

        let companionHostingView = NSHostingView(rootView: content().frame(width: width))
        companionHostingView.frame = NSRect(x: 0, y: 0, width: width, height: initialHeight)
        companionHostingView.wantsLayer = true
        companionHostingView.layer?.backgroundColor = .clear
        companionHostingView.sizingOptions = [.intrinsicContentSize]

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: width, height: initialHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        appearance = NSAppearance(named: .aqua)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        contentView = companionHostingView

        hostingViewSizeObservation = companionHostingView.observe(\.fittingSize, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, self.isPresented else { return }
                self.repositionToStatusItem()
            }
        }
    }

    override var canBecomeKey: Bool { true }

    func showAnchoredToStatusItem() {
        repositionToStatusItem()
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
        isPresented = true
        statusBarButton?.isHighlighted = true
        refreshOutsideClickMonitor()
    }

    func hide() {
        guard isPresented else {
            orderOut(nil)
            removeClickOutsideMonitor()
            return
        }

        orderOut(nil)
        isPresented = false
        statusBarButton?.isHighlighted = false
        removeClickOutsideMonitor()
        onClose()
    }

    func toggleAnchoredToStatusItem() {
        if isPresented {
            hide()
        } else {
            showAnchoredToStatusItem()
        }
    }

    func refreshOutsideClickMonitor() {
        removeClickOutsideMonitor()
        guard isPresented, !isPinnedProvider() else { return }

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self else { return }

            let clickLocation = NSEvent.mouseLocation
            guard !self.frame.contains(clickLocation) else { return }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard self.isPresented else { return }
                if self.shouldDeferOutsideClickDismissal() {
                    return
                }
                self.hide()
            }
        }
    }

    private func repositionToStatusItem() {
        let contentHeight = max(contentView?.fittingSize.height ?? frame.height, 1)
        let contentSize = NSSize(width: panelWidth, height: contentHeight)
        let origin = anchoredOrigin(for: contentSize)

        setFrame(
            NSRect(origin: origin, size: contentSize),
            display: true,
            animate: false
        )
    }

    private func anchoredOrigin(for panelSize: NSSize) -> NSPoint {
        guard let statusBarButton,
              let buttonWindow = statusBarButton.window else {
            var fallbackPoint = NSEvent.mouseLocation
            fallbackPoint.y -= panelSize.height + gapBelowStatusItem
            return fallbackPoint
        }

        let buttonRectInWindow = statusBarButton.convert(statusBarButton.bounds, to: nil)
        let buttonScreenRect = buttonWindow.convertToScreen(buttonRectInWindow)

        // The icon can be hidden by macOS (notch, crowded menu bar). Then its
        // window is off every screen, so anchor to the top-right instead.
        guard NSScreen.screens.contains(where: { $0.frame.intersects(buttonScreenRect) }) else {
            let fallbackVisibleFrame = NSScreen.main?.visibleFrame ?? .zero
            return NSPoint(
                x: fallbackVisibleFrame.maxX - panelSize.width - 12,
                y: fallbackVisibleFrame.maxY - panelSize.height - gapBelowStatusItem
            )
        }
        let visibleFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame

        var originX = buttonScreenRect.midX - panelSize.width / 2
        if let visibleFrame {
            originX = min(max(originX, visibleFrame.minX), visibleFrame.maxX - panelSize.width)
        }

        return NSPoint(
            x: originX,
            y: buttonScreenRect.minY - panelSize.height - gapBelowStatusItem
        )
    }

    private func removeClickOutsideMonitor() {
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
            self.clickOutsideMonitor = nil
        }
    }
}
