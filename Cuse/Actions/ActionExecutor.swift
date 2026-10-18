//
//  ActionExecutor.swift
//  Cuse
//
//  Autopilot action facade. Cuse core depends on ActionExecutor;
//  concrete action delivery lives behind CuseActionDriver.
//

import AppKit
import CuaDriverCore
import Foundation

enum ActionExecutorError: Error, LocalizedError {
    case targetAppUnavailable
    case unparseableKeyboardShortcut(String)
    case invalidScrollDirection(String)
    case highlightedTextRangeUnavailable
    case actionDriverDisabled(String)

    var errorDescription: String? {
        switch self {
        case .targetAppUnavailable:
            return "No target app is available for this autopilot action."
        case .unparseableKeyboardShortcut(let shortcutString):
            return "Couldn't parse keyboard shortcut \"\(shortcutString)\"."
        case .invalidScrollDirection(let direction):
            return "Invalid scroll direction \"\(direction)\"."
        case .highlightedTextRangeUnavailable:
            return "The highlighted text range is no longer available."
        case .actionDriverDisabled(let driverName):
            return "\(driverName) action driver is disabled."
        }
    }
}

@MainActor
final class ActionExecutor {

    static let shared = ActionExecutor(actionDriver: CuaActionDriver())

    private let actionDriver: CuseActionDriver
    var isActionDriverEnabledProvider: (@MainActor () -> Bool)?
    var actionDriverDisplayName: String = "CUA"

    init(actionDriver: CuseActionDriver) {
        self.actionDriver = actionDriver
    }

    func click(
        atGlobalScreenPoint globalScreenPoint: CGPoint,
        activatingTargetApp targetApp: NSRunningApplication? = nil
    ) async throws {
        let metadata = actionMetadata(
            targetApp: targetApp,
            extra: pointMetadata(globalScreenPoint)
        )
        recordActionEvent(name: "click", status: "started", metadata: metadata)
        do {
            try ensureActionDriverEnabled()
            try await actionDriver.click(
                atGlobalScreenPoint: globalScreenPoint,
                activatingTargetApp: targetApp
            )
            recordActionEvent(name: "click", status: "ok", metadata: metadata)
        } catch {
            recordActionEvent(
                name: "click",
                status: "failed",
                message: error.localizedDescription,
                metadata: metadata
            )
            throw error
        }
    }

    func rightClick(
        atGlobalScreenPoint globalScreenPoint: CGPoint,
        activatingTargetApp targetApp: NSRunningApplication? = nil
    ) async throws {
        let metadata = actionMetadata(
            targetApp: targetApp,
            extra: pointMetadata(globalScreenPoint)
        )
        recordActionEvent(name: "right_click", status: "started", metadata: metadata)
        do {
            try ensureActionDriverEnabled()
            try await actionDriver.rightClick(
                atGlobalScreenPoint: globalScreenPoint,
                activatingTargetApp: targetApp
            )
            recordActionEvent(name: "right_click", status: "ok", metadata: metadata)
        } catch {
            recordActionEvent(
                name: "right_click",
                status: "failed",
                message: error.localizedDescription,
                metadata: metadata
            )
            throw error
        }
    }

    func doubleClick(
        atGlobalScreenPoint globalScreenPoint: CGPoint,
        activatingTargetApp targetApp: NSRunningApplication? = nil
    ) async throws {
        let metadata = actionMetadata(
            targetApp: targetApp,
            extra: pointMetadata(globalScreenPoint)
        )
        recordActionEvent(name: "double_click", status: "started", metadata: metadata)
        do {
            try ensureActionDriverEnabled()
            try await actionDriver.doubleClick(
                atGlobalScreenPoint: globalScreenPoint,
                activatingTargetApp: targetApp
            )
            recordActionEvent(name: "double_click", status: "ok", metadata: metadata)
        } catch {
            recordActionEvent(
                name: "double_click",
                status: "failed",
                message: error.localizedDescription,
                metadata: metadata
            )
            throw error
        }
    }

    func pressKeyboardShortcut(
        _ shortcutString: String,
        activatingTargetApp targetApp: NSRunningApplication? = nil
    ) async throws {
        let metadata = actionMetadata(
            targetApp: targetApp,
            extra: ["shortcut": shortcutString]
        )
        recordActionEvent(name: "keyboard_shortcut", status: "started", metadata: metadata)
        do {
            try ensureActionDriverEnabled()
            try await actionDriver.pressKeyboardShortcut(
                shortcutString,
                activatingTargetApp: targetApp
            )
            recordActionEvent(name: "keyboard_shortcut", status: "ok", metadata: metadata)
        } catch {
            recordActionEvent(
                name: "keyboard_shortcut",
                status: "failed",
                message: error.localizedDescription,
                metadata: metadata
            )
            throw error
        }
    }

    func pressKey(
        _ keyName: String,
        activatingTargetApp targetApp: NSRunningApplication? = nil
    ) async throws {
        let metadata = actionMetadata(
            targetApp: targetApp,
            extra: ["key": keyName]
        )
        recordActionEvent(name: "press_key", status: "started", metadata: metadata)
        do {
            try ensureActionDriverEnabled()
            try await actionDriver.pressKey(
                keyName,
                activatingTargetApp: targetApp
            )
            recordActionEvent(name: "press_key", status: "ok", metadata: metadata)
        } catch {
            recordActionEvent(
                name: "press_key",
                status: "failed",
                message: error.localizedDescription,
                metadata: metadata
            )
            throw error
        }
    }

    func typeText(
        _ text: String,
        activatingTargetApp targetApp: NSRunningApplication? = nil
    ) async throws {
        let metadata = actionMetadata(
            targetApp: targetApp,
            extra: [
                "character_count": String(text.count),
                "preview": String(text.prefix(80))
            ]
        )
        recordActionEvent(name: "type_text", status: "started", metadata: metadata)
        do {
            try ensureActionDriverEnabled()
            try await actionDriver.typeText(
                text,
                activatingTargetApp: targetApp
            )
            recordActionEvent(name: "type_text", status: "ok", metadata: metadata)
        } catch {
            recordActionEvent(
                name: "type_text",
                status: "failed",
                message: error.localizedDescription,
                metadata: metadata
            )
            throw error
        }
    }

    func setFocusedValue(
        _ value: String,
        activatingTargetApp targetApp: NSRunningApplication? = nil
    ) async throws {
        let metadata = actionMetadata(
            targetApp: targetApp,
            extra: [
                "character_count": String(value.count),
                "preview": String(value.prefix(80))
            ]
        )
        recordActionEvent(name: "set_focused_value", status: "started", metadata: metadata)
        do {
            try ensureActionDriverEnabled()
            try await actionDriver.setFocusedValue(
                value,
                activatingTargetApp: targetApp
            )
            recordActionEvent(name: "set_focused_value", status: "ok", metadata: metadata)
        } catch {
            recordActionEvent(
                name: "set_focused_value",
                status: "failed",
                message: error.localizedDescription,
                metadata: metadata
            )
            throw error
        }
    }

    func scroll(
        direction: String,
        amount: Int = 3,
        by granularity: String = "line",
        activatingTargetApp targetApp: NSRunningApplication? = nil
    ) async throws {
        let metadata = actionMetadata(
            targetApp: targetApp,
            extra: [
                "direction": direction,
                "amount": String(amount),
                "granularity": granularity
            ]
        )
        recordActionEvent(name: "scroll", status: "started", metadata: metadata)
        do {
            try ensureActionDriverEnabled()
            try await actionDriver.scroll(
                direction: direction,
                amount: amount,
                by: granularity,
                activatingTargetApp: targetApp
            )
            recordActionEvent(name: "scroll", status: "ok", metadata: metadata)
        } catch {
            recordActionEvent(
                name: "scroll",
                status: "failed",
                message: error.localizedDescription,
                metadata: metadata
            )
            throw error
        }
    }

    func openApplication(named applicationName: String) async throws {
        let metadata = ["application": applicationName]
        recordActionEvent(name: "open_application", status: "started", metadata: metadata)
        do {
            try ensureActionDriverEnabled()
            try await actionDriver.openApplication(named: applicationName)
            recordActionEvent(name: "open_application", status: "ok", metadata: metadata)
        } catch {
            recordActionEvent(
                name: "open_application",
                status: "failed",
                message: error.localizedDescription,
                metadata: metadata
            )
            throw error
        }
    }

    func openURL(_ rawURLString: String, preferredApplicationName: String? = nil) async throws {
        var metadata = ["url": rawURLString]
        if let preferredApplicationName {
            metadata["preferred_application"] = preferredApplicationName
        }
        recordActionEvent(name: "open_url", status: "started", metadata: metadata)
        do {
            try ensureActionDriverEnabled()
            try await actionDriver.openURL(
                rawURLString,
                preferredApplicationName: preferredApplicationName
            )
            recordActionEvent(name: "open_url", status: "ok", metadata: metadata)
        } catch {
            recordActionEvent(
                name: "open_url",
                status: "failed",
                message: error.localizedDescription,
                metadata: metadata
            )
            throw error
        }
    }

    func setPendingTextReplacementRange(
        processIdentifier: pid_t,
        location: Int,
        length: Int
    ) {
        actionDriver.setPendingTextReplacementRange(
            processIdentifier: processIdentifier,
            location: location,
            length: length
        )
        recordActionEvent(
            name: "arm_text_replacement",
            status: "ok",
            metadata: [
                "target_pid": String(processIdentifier),
                "location": String(location),
                "length": String(length)
            ]
        )
    }

    private func ensureActionDriverEnabled() throws {
        guard isActionDriverEnabledProvider?() ?? true else {
            throw ActionExecutorError.actionDriverDisabled(actionDriverDisplayName)
        }
    }

    private func actionMetadata(
        targetApp: NSRunningApplication?,
        extra: [String: String]
    ) -> [String: String] {
        var metadata = extra
        if let targetApp {
            metadata["target_app"] = targetApp.localizedName ?? "unknown"
            metadata["target_bundle"] = targetApp.bundleIdentifier ?? "unknown"
            metadata["target_pid"] = String(targetApp.processIdentifier)
        }
        return metadata
    }

    private func pointMetadata(_ point: CGPoint) -> [String: String] {
        [
            "x": String(format: "%.1f", point.x),
            "y": String(format: "%.1f", point.y)
        ]
    }

    private func recordActionEvent(
        name: String,
        status: String,
        message: String? = nil,
        metadata: [String: String]
    ) {
        PipelineLogStore.shared.record(
            category: "action",
            name: name,
            status: status,
            message: message,
            metadata: metadata
        )
    }
}

@MainActor
final class CuaActionDriver: CuseActionDriver {

    private let postActivationSettleSeconds: TimeInterval = 0.08
    private let postForegroundActivationSettleSeconds: TimeInterval = 0.35
    private var pendingTextReplacementRangeByProcessIdentifier: [pid_t: CFRange] = [:]

    // MARK: - Public API

    func click(
        atGlobalScreenPoint globalScreenPoint: CGPoint,
        activatingTargetApp targetApp: NSRunningApplication? = nil
    ) async throws {
        try AXInput.requireAuthorized()

        let targetApplication = try targetApplication(for: targetApp)
        try await activateTargetApplicationIfNeeded(targetApplication)

        let targetProcessIdentifier = targetApplication.processIdentifier
        let cuaScreenPoint = convertGlobalAppKitPointToCuaScreenPoint(globalScreenPoint)

        try MouseInput.click(
            at: cuaScreenPoint,
            toPid: targetProcessIdentifier,
            button: .left,
            count: 1,
            useFrontmostHIDPath: true
        )
        print("[ActionExecutor] CUA clicked pid=\(targetProcessIdentifier) at \(cuaScreenPoint)")
        postUserInterfaceActionExecuted()
    }

    func rightClick(
        atGlobalScreenPoint globalScreenPoint: CGPoint,
        activatingTargetApp targetApp: NSRunningApplication? = nil
    ) async throws {
        try await click(
            atGlobalScreenPoint: globalScreenPoint,
            activatingTargetApp: targetApp,
            button: .right,
            count: 1
        )
    }

    func doubleClick(
        atGlobalScreenPoint globalScreenPoint: CGPoint,
        activatingTargetApp targetApp: NSRunningApplication? = nil
    ) async throws {
        try await click(
            atGlobalScreenPoint: globalScreenPoint,
            activatingTargetApp: targetApp,
            button: .left,
            count: 2
        )
    }

    func pressKeyboardShortcut(
        _ shortcutString: String,
        activatingTargetApp targetApp: NSRunningApplication? = nil
    ) async throws {
        try AXInput.requireAuthorized()

        let targetApplication = try targetApplication(for: targetApp)
        try await activateTargetApplicationIfNeeded(targetApplication)

        let targetProcessIdentifier = targetApplication.processIdentifier
        let hotkeyTokens = try normalizedHotkeyTokens(from: shortcutString)

        do {
            try KeyboardInput.hotkey(
                hotkeyTokens,
                toPid: targetProcessIdentifier
            )
            print("[ActionExecutor] CUA pressed shortcut \"\(shortcutString)\" on pid=\(targetProcessIdentifier)")
        } catch {
            try postKeyboardShortcutUsingQuartz(hotkeyTokens)
            print("[ActionExecutor] Quartz fallback pressed shortcut \"\(shortcutString)\" on pid=\(targetProcessIdentifier) after CUA failed: \(error.localizedDescription)")
        }
        postUserInterfaceActionExecuted()
    }

    func pressKey(
        _ keyName: String,
        activatingTargetApp targetApp: NSRunningApplication? = nil
    ) async throws {
        try AXInput.requireAuthorized()

        let targetApplication = try targetApplication(for: targetApp)
        try await activateTargetApplicationIfNeeded(targetApplication)
        let targetProcessIdentifier = targetApplication.processIdentifier

        if normalizeShortcutToken(keyName) == "delete",
           hasPendingTextReplacementRange(for: targetProcessIdentifier) {
            let focusedElement = try AXInput.focusedElement(pid: targetProcessIdentifier)
            try applyPendingTextReplacementRange(
                processIdentifier: targetProcessIdentifier,
                focusedElement: focusedElement
            )
        }

        let normalizedKeyName = normalizeShortcutToken(keyName)
        do {
            try KeyboardInput.press(
                normalizedKeyName,
                toPid: targetProcessIdentifier
            )
            print("[ActionExecutor] CUA pressed key \"\(keyName)\" on pid=\(targetProcessIdentifier)")
        } catch {
            try postKeyUsingQuartz(normalizedKeyName)
            print("[ActionExecutor] Quartz fallback pressed key \"\(keyName)\" on pid=\(targetProcessIdentifier) after CUA failed: \(error.localizedDescription)")
        }
        postUserInterfaceActionExecuted()
    }

    func typeText(
        _ text: String,
        activatingTargetApp targetApp: NSRunningApplication? = nil
    ) async throws {
        try AXInput.requireAuthorized()

        let targetApplication = try targetApplication(for: targetApp)
        try await activateTargetApplicationIfNeeded(targetApplication)

        let targetProcessIdentifier = targetApplication.processIdentifier

        if shouldTypeTextUsingPhysicalKeys(text, targetApplication: targetApplication) {
            try await typeTextUsingPhysicalKeys(text)
            print("[ActionExecutor] typed skill-directed modal input \"\(text)\" via physical key events on pid=\(targetProcessIdentifier)")
            postUserInterfaceActionExecuted()
            return
        }

        let hasArmedHighlightReplacementRange = hasPendingTextReplacementRange(
            for: targetProcessIdentifier
        )

        do {
            let focusedElement = try AXInput.focusedElement(pid: targetProcessIdentifier)
            if !hasArmedHighlightReplacementRange, Self.isInsideWebContent(focusedElement) {
                // Web pages ignore text inserted through AXSelectedText: the
                // characters appear, but the page's input events never fire, so
                // Wikipedia's search submitted an empty query. A real paste fires
                // them. The clipboard is restored right after.
                try await pasteTextUsingClipboard(text, toPid: targetProcessIdentifier)
                print("[ActionExecutor] CUA pasted \(text.count) characters into web content on pid=\(targetProcessIdentifier)")
                postUserInterfaceActionExecuted()
                return
            }
            if hasArmedHighlightReplacementRange {
                try applyPendingTextReplacementRange(
                    processIdentifier: targetProcessIdentifier,
                    focusedElement: focusedElement
                )
            }
            try AXInput.setAttribute(
                "AXSelectedText",
                on: focusedElement,
                value: text as CFString
            )
            print("[ActionExecutor] CUA inserted \(text.count) characters via AX on pid=\(targetProcessIdentifier)")
            postUserInterfaceActionExecuted()
        } catch {
            guard !hasArmedHighlightReplacementRange else {
                print("[ActionExecutor] refused key-event fallback because highlighted range could not be applied: \(error)")
                throw ActionExecutorError.highlightedTextRangeUnavailable
            }

            try await pasteTextUsingClipboard(
                text,
                toPid: targetProcessIdentifier
            )
            print("[ActionExecutor] CUA pasted \(text.count) characters via clipboard hotkey on pid=\(targetProcessIdentifier)")
            postUserInterfaceActionExecuted()
        }
    }

    func setFocusedValue(
        _ value: String,
        activatingTargetApp targetApp: NSRunningApplication? = nil
    ) async throws {
        try AXInput.requireAuthorized()

        let targetApplication = try targetApplication(for: targetApp)
        try await activateTargetApplicationIfNeeded(targetApplication)

        let targetProcessIdentifier = targetApplication.processIdentifier
        let focusedElement = try AXInput.focusedElement(pid: targetProcessIdentifier)

        if hasPendingTextReplacementRange(for: targetProcessIdentifier) {
            try applyPendingTextReplacementRange(
                processIdentifier: targetProcessIdentifier,
                focusedElement: focusedElement
            )
            try AXInput.setAttribute(
                "AXSelectedText",
                on: focusedElement,
                value: value as CFString
            )
            print("[ActionExecutor] CUA replaced highlighted text via setValue payload on pid=\(targetProcessIdentifier)")
            postUserInterfaceActionExecuted()
            return
        }

        try AXInput.setAttribute(
            "AXValue",
            on: focusedElement,
            value: value as CFString
        )
        print("[ActionExecutor] CUA set focused AXValue on pid=\(targetProcessIdentifier)")
        postUserInterfaceActionExecuted()
    }

    func scroll(
        direction: String,
        amount: Int = 3,
        by granularity: String = "line",
        activatingTargetApp targetApp: NSRunningApplication? = nil
    ) async throws {
        try AXInput.requireAuthorized()

        let targetApplication = try targetApplication(for: targetApp)
        try await activateTargetApplicationIfNeeded(targetApplication)

        guard let keyName = scrollKeyName(direction: direction, granularity: granularity) else {
            throw ActionExecutorError.invalidScrollDirection("\(direction)/\(granularity)")
        }

        let targetProcessIdentifier = targetApplication.processIdentifier
        let clampedAmount = max(1, min(amount, 50))
        for _ in 0..<clampedAmount {
            try KeyboardInput.press(keyName, toPid: targetProcessIdentifier)
        }
        print("[ActionExecutor] CUA scrolled \(direction) via \(clampedAmount)x \(keyName) on pid=\(targetProcessIdentifier)")
        postUserInterfaceActionExecuted()
    }

    func openApplication(named applicationName: String) async throws {
        let launchedApplication = try await AppLauncher.launch(
            name: applicationName,
            additionalArguments: remoteDebuggingArgumentsIfChromiumBrowser(applicationName)
        )
        if let runningApplication = NSRunningApplication(processIdentifier: launchedApplication.pid) {
            try await bringApplicationToForeground(runningApplication)
        }
        print("[ActionExecutor] CUA opened app \"\(applicationName)\" pid=\(launchedApplication.pid)")
        postUserInterfaceActionExecuted()
    }

    func openURL(_ rawURLString: String, preferredApplicationName: String? = nil) async throws {
        let url = normalizedURL(from: rawURLString)
        if let preferredApplicationName, !preferredApplicationName.isEmpty {
            let launchedApplication = try await AppLauncher.launch(
                name: preferredApplicationName,
                urls: [url],
                additionalArguments: remoteDebuggingArgumentsIfChromiumBrowser(preferredApplicationName)
            )
            if let runningApplication = NSRunningApplication(processIdentifier: launchedApplication.pid) {
                try await bringApplicationToForeground(runningApplication)
            }
        } else {
            let launchedApplication = try await launchDefaultApplication(for: url)
            if let runningApplication = NSRunningApplication(processIdentifier: launchedApplication.pid) {
                try await bringApplicationToForeground(runningApplication)
            }
        }

        if let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }

        print("[ActionExecutor] opened URL \(url.absoluteString)")
        postUserInterfaceActionExecuted()
    }

    func setPendingTextReplacementRange(
        processIdentifier: pid_t,
        location: Int,
        length: Int
    ) {
        guard location >= 0, length > 0 else { return }
        pendingTextReplacementRangeByProcessIdentifier[processIdentifier] = CFRange(
            location: location,
            length: length
        )
        print("[ActionExecutor] armed pending text replacement range pid=\(processIdentifier) location=\(location) length=\(length)")
    }

    private func click(
        atGlobalScreenPoint globalScreenPoint: CGPoint,
        activatingTargetApp targetApp: NSRunningApplication?,
        button: MouseInput.Button,
        count: Int
    ) async throws {
        try AXInput.requireAuthorized()

        let targetApplication = try targetApplication(for: targetApp)
        try await activateTargetApplicationIfNeeded(targetApplication)

        let targetProcessIdentifier = targetApplication.processIdentifier
        let cuaScreenPoint = convertGlobalAppKitPointToCuaScreenPoint(globalScreenPoint)

        try MouseInput.click(
            at: cuaScreenPoint,
            toPid: targetProcessIdentifier,
            button: button,
            count: count,
            useFrontmostHIDPath: true
        )
        print("[ActionExecutor] CUA \(button.rawValue)-clicked pid=\(targetProcessIdentifier) at \(cuaScreenPoint)")
        postUserInterfaceActionExecuted()
    }

    private func postUserInterfaceActionExecuted() {
        NotificationCenter.default.post(name: .cuseUserInterfaceActionExecuted, object: nil)
    }

    // MARK: - Target App

    private func targetApplication(for targetApp: NSRunningApplication?) throws -> NSRunningApplication {
        if let targetApp {
            return targetApp
        }
        if let userTargetAppOverride = AccessibilityTreeResolver.userTargetAppOverride {
            return userTargetAppOverride
        }
        if let frontmostApplication = NSWorkspace.shared.frontmostApplication {
            return frontmostApplication
        }
        throw ActionExecutorError.targetAppUnavailable
    }

    private func activateTargetApplicationIfNeeded(_ targetApplication: NSRunningApplication) async throws {
        if !targetApplication.isActive {
            targetApplication.activate()
            try await Task.sleep(nanoseconds: UInt64(postActivationSettleSeconds * 1_000_000_000))
        }
    }

    private func bringApplicationToForeground(_ targetApplication: NSRunningApplication) async throws {
        targetApplication.unhide()
        targetApplication.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        try await Task.sleep(nanoseconds: UInt64(postForegroundActivationSettleSeconds * 1_000_000_000))
        raiseMainWindowIfPossible(for: targetApplication)
        try await Task.sleep(nanoseconds: UInt64(postActivationSettleSeconds * 1_000_000_000))
    }

    private func raiseMainWindowIfPossible(for targetApplication: NSRunningApplication) {
        let processIdentifier = targetApplication.processIdentifier
        guard processIdentifier > 0 else { return }

        let appElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.2)

        if let focusedWindow = accessibilityWindowAttribute(
            "AXFocusedWindow",
            of: appElement
        ) {
            AXUIElementPerformAction(focusedWindow, kAXRaiseAction as CFString)
            return
        }

        var windowsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              let firstWindow = windows.first else {
            return
        }

        AXUIElementPerformAction(firstWindow, kAXRaiseAction as CFString)
    }

    private func accessibilityWindowAttribute(
        _ attributeName: String,
        of element: AXUIElement
    ) -> AXUIElement? {
        var valueRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attributeName as CFString, &valueRef) == .success,
              let valueRef else {
            return nil
        }
        return valueRef as! AXUIElement
    }

    private func hasPendingTextReplacementRange(for processIdentifier: pid_t) -> Bool {
        pendingTextReplacementRangeByProcessIdentifier[processIdentifier] != nil
    }

    private func applyPendingTextReplacementRange(
        processIdentifier: pid_t,
        focusedElement: AXUIElement
    ) throws {
        guard var pendingRange = pendingTextReplacementRangeByProcessIdentifier[processIdentifier] else {
            return
        }

        guard let selectedRangeValue = AXValueCreate(.cfRange, &pendingRange) else {
            throw ActionExecutorError.highlightedTextRangeUnavailable
        }

        try AXInput.setAttribute(
            "AXSelectedTextRange",
            on: focusedElement,
            value: selectedRangeValue
        )
        pendingTextReplacementRangeByProcessIdentifier.removeValue(forKey: processIdentifier)
        print("[ActionExecutor] applied pending text replacement range pid=\(processIdentifier) location=\(pendingRange.location) length=\(pendingRange.length)")
    }

    private func pasteTextUsingClipboard(
        _ text: String,
        toPid targetProcessIdentifier: pid_t
    ) async throws {
        let pasteboard = NSPasteboard.general
        let previousPasteboardItems = copyPasteboardItems(from: pasteboard)

        let stagedTextItem = NSPasteboardItem()
        stagedTextItem.setString(text, forType: .string)

        pasteboard.clearContents()
        pasteboard.writeObjects([stagedTextItem])

        do {
            try KeyboardInput.hotkey(["cmd", "v"], toPid: targetProcessIdentifier)
            try await Task.sleep(nanoseconds: 150_000_000)
            restorePasteboard(pasteboard, items: previousPasteboardItems)
        } catch {
            restorePasteboard(pasteboard, items: previousPasteboardItems)
            throw error
        }
    }

    /// True when the element sits inside a web page (Chrome, Safari, or an
    /// Electron app), found by an AXWebArea among its first dozen ancestors.
    private static func isInsideWebContent(_ element: AXUIElement) -> Bool {
        var currentElement = element
        for _ in 0..<12 {
            var roleValue: CFTypeRef?
            AXUIElementCopyAttributeValue(currentElement, kAXRoleAttribute as CFString, &roleValue)
            if (roleValue as? String) == "AXWebArea" { return true }
            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(currentElement, kAXParentAttribute as CFString, &parentValue) == .success,
                  let parentValue, CFGetTypeID(parentValue) == AXUIElementGetTypeID() else { return false }
            currentElement = parentValue as! AXUIElement
        }
        return false
    }

    private func shouldTypeTextUsingPhysicalKeys(
        _ text: String,
        targetApplication: NSRunningApplication
    ) -> Bool {
        MarkdownAppSkillRegistry.shared
            .skill(for: targetApplication)?
            .shouldTypeUsingPhysicalKeys(text) == true
    }

    private func typeTextUsingPhysicalKeys(_ text: String) async throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for character in trimmedText {
            let keyName = String(character)
            try postKeyUsingQuartz(keyName)
            try await Task.sleep(nanoseconds: 35_000_000)
        }
    }

    private func copyPasteboardItems(from pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        pasteboard.pasteboardItems?.map { pasteboardItem in
            let copiedPasteboardItem = NSPasteboardItem()
            for type in pasteboardItem.types {
                if let data = pasteboardItem.data(forType: type) {
                    copiedPasteboardItem.setData(data, forType: type)
                } else if let string = pasteboardItem.string(forType: type) {
                    copiedPasteboardItem.setString(string, forType: type)
                }
            }
            return copiedPasteboardItem
        } ?? []
    }

    private func restorePasteboard(
        _ pasteboard: NSPasteboard,
        items: [NSPasteboardItem]
    ) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items)
    }

    private func normalizedURL(from rawURLString: String) -> URL {
        let trimmedURLString = rawURLString.trimmingCharacters(in: .whitespacesAndNewlines)

        if let url = URL(string: trimmedURLString), url.scheme != nil {
            return url
        }

        if trimmedURLString.hasPrefix("/") || trimmedURLString.hasPrefix("~") {
            let expandedPath = (trimmedURLString as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expandedPath)
        }

        return URL(string: "https://\(trimmedURLString)") ?? URL(fileURLWithPath: trimmedURLString)
    }

    private func launchDefaultApplication(for url: URL) async throws -> AppInfo {
        if let defaultApplicationURL = NSWorkspace.shared.urlForApplication(toOpen: url),
           let bundleIdentifier = Bundle(url: defaultApplicationURL)?.bundleIdentifier {
            return try await AppLauncher.launch(
                bundleId: bundleIdentifier,
                urls: [url],
                additionalArguments: remoteDebuggingArgumentsIfChromiumBrowser(bundleIdentifier)
            )
        }

        return try await AppLauncher.launch(
            name: "Safari",
            urls: [url]
        )
    }

    private func remoteDebuggingArgumentsIfChromiumBrowser(_ applicationNameOrBundleIdentifier: String) -> [String] {
        let normalized = applicationNameOrBundleIdentifier.lowercased()
        let isChromiumBrowser = normalized.contains("chrome")
            || normalized.contains("chromium")
            || normalized.contains("brave")
            || normalized.contains("edge")
            || normalized.contains("thebrowser")
            || normalized.contains("arc")

        guard isChromiumBrowser else { return [] }
        return ["--remote-debugging-port=9222"]
    }

    // MARK: - Coordinate Conversion

    /// Cuse stores global points in AppKit coordinates (bottom-left
    /// origin). CUA's pixel-addressed input primitives use screen points
    /// with a top-left origin.
    private func convertGlobalAppKitPointToCuaScreenPoint(_ globalAppKitPoint: CGPoint) -> CGPoint {
        guard let primaryScreen = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.main else {
            return globalAppKitPoint
        }
        return CGPoint(
            x: globalAppKitPoint.x,
            y: primaryScreen.frame.height - globalAppKitPoint.y
        )
    }

    // MARK: - Shortcut Parsing

    private func normalizedHotkeyTokens(from shortcutString: String) throws -> [String] {
        let rawTokens = shortcutString
            .split(whereSeparator: { $0 == "+" || $0 == "-" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !rawTokens.isEmpty else {
            throw ActionExecutorError.unparseableKeyboardShortcut(shortcutString)
        }

        var modifierTokens: [String] = []
        var finalKeyToken: String?

        for rawToken in rawTokens {
            let normalizedToken = normalizeShortcutToken(rawToken)
            if Self.modifierTokens.contains(normalizedToken) {
                modifierTokens.append(normalizedToken)
            } else {
                guard finalKeyToken == nil else {
                    throw ActionExecutorError.unparseableKeyboardShortcut(shortcutString)
                }
                finalKeyToken = normalizedToken
            }
        }

        guard let finalKeyToken else {
            throw ActionExecutorError.unparseableKeyboardShortcut(shortcutString)
        }

        return modifierTokens + [finalKeyToken]
    }

    private func postKeyboardShortcutUsingQuartz(_ hotkeyTokens: [String]) throws {
        let modifierTokens = hotkeyTokens.dropLast()
        guard let finalKeyToken = hotkeyTokens.last else {
            throw ActionExecutorError.unparseableKeyboardShortcut("")
        }

        let modifierKeys = try modifierTokens.map { try quartzModifierKey(for: $0) }
        let finalKeyCode = try quartzKeyCode(for: finalKeyToken)
        let activeFlags = quartzEventFlags(for: modifierKeys)

        for modifierKey in modifierKeys {
            postQuartzKeyEvent(
                keyCode: modifierKey.keyCode,
                isKeyDown: true,
                flags: activeFlags
            )
        }

        postQuartzKeyEvent(keyCode: finalKeyCode, isKeyDown: true, flags: activeFlags)
        postQuartzKeyEvent(keyCode: finalKeyCode, isKeyDown: false, flags: activeFlags)

        for modifierKey in modifierKeys.reversed() {
            postQuartzKeyEvent(
                keyCode: modifierKey.keyCode,
                isKeyDown: false,
                flags: []
            )
        }
    }

    private func postKeyUsingQuartz(_ keyName: String) throws {
        let keyCode = try quartzKeyCode(for: keyName)
        postQuartzKeyEvent(keyCode: keyCode, isKeyDown: true, flags: [])
        postQuartzKeyEvent(keyCode: keyCode, isKeyDown: false, flags: [])
    }

    private func postQuartzKeyEvent(
        keyCode: CGKeyCode,
        isKeyDown: Bool,
        flags: CGEventFlags
    ) {
        let event = CGEvent(
            keyboardEventSource: CGEventSource(stateID: .hidSystemState),
            virtualKey: keyCode,
            keyDown: isKeyDown
        )
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    private func quartzModifierKey(for token: String) throws -> QuartzModifierKey {
        switch token {
        case "cmd", "command":
            return QuartzModifierKey(keyCode: 55, flag: .maskCommand)
        case "shift":
            return QuartzModifierKey(keyCode: 56, flag: .maskShift)
        case "option", "alt":
            return QuartzModifierKey(keyCode: 58, flag: .maskAlternate)
        case "ctrl", "control":
            return QuartzModifierKey(keyCode: 59, flag: .maskControl)
        default:
            throw ActionExecutorError.unparseableKeyboardShortcut(token)
        }
    }

    private func quartzEventFlags(for modifierKeys: [QuartzModifierKey]) -> CGEventFlags {
        modifierKeys.reduce(CGEventFlags()) { combinedFlags, modifierKey in
            combinedFlags.union(modifierKey.flag)
        }
    }

    private func quartzKeyCode(for keyName: String) throws -> CGKeyCode {
        let normalizedKeyName = keyName.lowercased()
        if normalizedKeyName.count == 1,
           let character = normalizedKeyName.unicodeScalars.first,
           let keyCode = Self.quartzKeyCodeByCharacter[character] {
            return keyCode
        }

        if let keyCode = Self.quartzSpecialKeyCodes[normalizedKeyName] {
            return keyCode
        }

        throw ActionExecutorError.unparseableKeyboardShortcut(keyName)
    }

    private func normalizeShortcutToken(_ token: String) -> String {
        let normalizedRawToken = token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
            .lowercased()

        switch normalizedRawToken {
        case "cmd", "command", "⌘":
            return "cmd"
        case "opt", "option", "alt", "⌥":
            return "option"
        case "ctrl", "control", "⌃":
            return "ctrl"
        case "shift", "⇧":
            return "shift"
        case "esc":
            return "escape"
        case "del", "backspace":
            return "delete"
        case "return":
            return "return"
        default:
            return normalizedRawToken
        }
    }

    private func scrollKeyName(direction: String, granularity: String) -> String? {
        let normalizedDirection = direction.lowercased()
        let normalizedGranularity = granularity.lowercased()
        switch (normalizedDirection, normalizedGranularity) {
        case ("up", "line"): return "up"
        case ("down", "line"): return "down"
        case ("left", "line"): return "left"
        case ("right", "line"): return "right"
        case ("up", "page"): return "pageup"
        case ("down", "page"): return "pagedown"
        case ("left", "page"): return "left"
        case ("right", "page"): return "right"
        default: return nil
        }
    }

    private static let modifierTokens: Set<String> = [
        "cmd",
        "command",
        "shift",
        "option",
        "alt",
        "ctrl",
        "control",
        "fn"
    ]

    private struct QuartzModifierKey {
        let keyCode: CGKeyCode
        let flag: CGEventFlags
    }

    private static let quartzKeyCodeByCharacter: [UnicodeScalar: CGKeyCode] = [
        "a": 0,
        "s": 1,
        "d": 2,
        "f": 3,
        "h": 4,
        "g": 5,
        "z": 6,
        "x": 7,
        "c": 8,
        "v": 9,
        "b": 11,
        "q": 12,
        "w": 13,
        "e": 14,
        "r": 15,
        "y": 16,
        "t": 17,
        "1": 18,
        "2": 19,
        "3": 20,
        "4": 21,
        "6": 22,
        "5": 23,
        "=": 24,
        "9": 25,
        "7": 26,
        "-": 27,
        "8": 28,
        "0": 29,
        "]": 30,
        "o": 31,
        "u": 32,
        "[": 33,
        "i": 34,
        "p": 35,
        "l": 37,
        "j": 38,
        "'": 39,
        "k": 40,
        ";": 41,
        "\\": 42,
        ",": 43,
        "/": 44,
        "n": 45,
        "m": 46,
        ".": 47,
        "`": 50
    ]

    private static let quartzSpecialKeyCodes: [String: CGKeyCode] = [
        "return": 36,
        "enter": 36,
        "tab": 48,
        "space": 49,
        "delete": 51,
        "escape": 53,
        "left": 123,
        "right": 124,
        "down": 125,
        "up": 126,
        "pageup": 116,
        "pagedown": 121,
        "home": 115,
        "end": 119,
        "forwarddelete": 117,
        "f1": 122,
        "f2": 120,
        "f3": 99,
        "f4": 118,
        "f5": 96,
        "f6": 97,
        "f7": 98,
        "f8": 100,
        "f9": 101,
        "f10": 109,
        "f11": 103,
        "f12": 111
    ]
}
