//
//  GlobalHighlightShortcutMonitor.swift
//  Cuse
//
//  Hold control + shift and move the mouse to draw a freeform focus
//  trail. The event tap is listen-only: it never blocks user input.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalHighlightShortcutMonitor: ObservableObject {
    enum HighlightTransition {
        case began(CGPoint)
        case moved(CGPoint)
        case ended
    }

    let highlightTransitionPublisher = PassthroughSubject<HighlightTransition, Never>()

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?

    @Published private(set) var isHighlightShortcutCurrentlyPressed = false

    deinit {
        stop()
    }

    func start() {
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [
            .flagsChanged,
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged
        ]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let monitor = Unmanaged<GlobalHighlightShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return monitor.handleGlobalEventTap(eventType: eventType, event: event)
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global highlight: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global highlight: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        if isHighlightShortcutCurrentlyPressed {
            highlightTransitionPublisher.send(.ended)
        }
        isHighlightShortcutCurrentlyPressed = false

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let isHighlightHeld = Self.isHighlightShortcutHeld(event.flags)
        let currentMouseLocation = NSEvent.mouseLocation
        let isMouseMovementEvent = eventType == .mouseMoved
            || eventType == .leftMouseDragged
            || eventType == .rightMouseDragged

        if isHighlightHeld && !isHighlightShortcutCurrentlyPressed {
            isHighlightShortcutCurrentlyPressed = true
            highlightTransitionPublisher.send(.began(currentMouseLocation))
        } else if !isHighlightHeld && isHighlightShortcutCurrentlyPressed {
            isHighlightShortcutCurrentlyPressed = false
            highlightTransitionPublisher.send(.ended)
        } else if isHighlightHeld && isMouseMovementEvent {
            highlightTransitionPublisher.send(.moved(currentMouseLocation))
        }

        return Unmanaged.passUnretained(event)
    }

    private static func isHighlightShortcutHeld(_ flags: CGEventFlags) -> Bool {
        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))
        return modifierFlags.contains(.control)
            && modifierFlags.contains(.shift)
            && !modifierFlags.contains(.option)
            && !modifierFlags.contains(.command)
    }
}
