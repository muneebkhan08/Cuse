//
//  GlobalRadialInputShortcutMonitor.swift
//  Cuse
//
//  Hold Control + Option + Command to open the cursor-centered input switcher.
//  Mouse movement while held updates the highlighted wedge; release selects it.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalRadialInputShortcutMonitor: ObservableObject {
    enum SwitcherTransition {
        case began(CGPoint)
        case moved(CGPoint)
        case ended(CGPoint)
    }

    let switcherTransitionPublisher = PassthroughSubject<SwitcherTransition, Never>()

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    @Published private(set) var isShortcutCurrentlyPressed = false

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

            let monitor = Unmanaged<GlobalRadialInputShortcutMonitor>
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
            print("⚠️ Global radial input: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global radial input: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        if isShortcutCurrentlyPressed {
            switcherTransitionPublisher.send(.ended(NSEvent.mouseLocation))
        }
        isShortcutCurrentlyPressed = false

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

        let modifierCombinationIsHeld = Self.isSwitcherModifierCombinationHeld(event.flags)
        let mouseLocation = NSEvent.mouseLocation
        let isMouseMovementEvent = eventType == .mouseMoved
            || eventType == .leftMouseDragged
            || eventType == .rightMouseDragged

        switch eventType {
        case .flagsChanged:
            if modifierCombinationIsHeld && !isShortcutCurrentlyPressed {
                isShortcutCurrentlyPressed = true
                switcherTransitionPublisher.send(.began(mouseLocation))
            } else if isShortcutCurrentlyPressed && !modifierCombinationIsHeld {
                endSwitcherIfNeeded(at: mouseLocation)
            }
        case _ where isShortcutCurrentlyPressed && isMouseMovementEvent:
            switcherTransitionPublisher.send(.moved(mouseLocation))
        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }

    private func endSwitcherIfNeeded(at mouseLocation: CGPoint) {
        guard isShortcutCurrentlyPressed else { return }
        isShortcutCurrentlyPressed = false
        switcherTransitionPublisher.send(.ended(mouseLocation))
    }

    private static func isSwitcherModifierCombinationHeld(_ flags: CGEventFlags) -> Bool {
        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))
        return modifierFlags.contains(.control)
            && modifierFlags.contains(.option)
            && modifierFlags.contains(.command)
            && !modifierFlags.contains(.shift)
    }
}
