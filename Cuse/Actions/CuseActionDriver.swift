//
//  CuseActionDriver.swift
//  Cuse
//
//  Action driver boundary. Cuse core asks for semantic desktop actions;
//  concrete drivers decide whether those actions are delivered through CUA,
//  AX, browser DOM, AppleScript, or a test/no-op backend.
//

import AppKit
import Foundation

@MainActor
protocol CuseActionDriver {
    func click(
        atGlobalScreenPoint globalScreenPoint: CGPoint,
        activatingTargetApp targetApp: NSRunningApplication?
    ) async throws

    func rightClick(
        atGlobalScreenPoint globalScreenPoint: CGPoint,
        activatingTargetApp targetApp: NSRunningApplication?
    ) async throws

    func doubleClick(
        atGlobalScreenPoint globalScreenPoint: CGPoint,
        activatingTargetApp targetApp: NSRunningApplication?
    ) async throws

    func pressKeyboardShortcut(
        _ shortcutString: String,
        activatingTargetApp targetApp: NSRunningApplication?
    ) async throws

    func pressKey(
        _ keyName: String,
        activatingTargetApp targetApp: NSRunningApplication?
    ) async throws

    func typeText(
        _ text: String,
        activatingTargetApp targetApp: NSRunningApplication?
    ) async throws

    func setFocusedValue(
        _ value: String,
        activatingTargetApp targetApp: NSRunningApplication?
    ) async throws

    func scroll(
        direction: String,
        amount: Int,
        by granularity: String,
        activatingTargetApp targetApp: NSRunningApplication?
    ) async throws

    func openApplication(named applicationName: String) async throws

    func openURL(
        _ rawURLString: String,
        preferredApplicationName: String?
    ) async throws

    func setPendingTextReplacementRange(
        processIdentifier: pid_t,
        location: Int,
        length: Int
    )
}
