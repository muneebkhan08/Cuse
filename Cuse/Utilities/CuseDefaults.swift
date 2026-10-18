//
//  CuseDefaults.swift
//  Cuse
//
//  Centralized UserDefaults access for app preferences. Keep the raw keys
//  here so feature code can read intent instead of string literals.
//

import Foundation

enum CuseDefaults {
    enum Key: String {
        case hasCompletedOnboarding = "hasCompletedModeSetup"
        case hasScreenContentPermission
        case isAccurateGroundingEnabled
        case isAutopilotEnabled
        case isCuaActionDriverEnabled
        case isDetectionOverlayEnabled
        case isNekoModeEnabled
        case isPanelPinned
        case isScreenshotStreamingEnabled
        case hasPreviouslyConfirmedScreenRecordingPermission = "com.learningbuddy.hasPreviouslyConfirmedScreenRecordingPermission"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "NSInitialToolTipDelay": 0,
            Key.hasCompletedOnboarding.rawValue: false,
            Key.hasScreenContentPermission.rawValue: false,
            Key.hasPreviouslyConfirmedScreenRecordingPermission.rawValue: false,
            Key.isAccurateGroundingEnabled.rawValue: false,
            Key.isAutopilotEnabled.rawValue: true,
            Key.isCuaActionDriverEnabled.rawValue: true,
            Key.isDetectionOverlayEnabled.rawValue: false,
            Key.isNekoModeEnabled.rawValue: false,
            Key.isPanelPinned.rawValue: false,
            Key.isScreenshotStreamingEnabled.rawValue: true
        ])
    }

    static var selectedMode: CuseMode {
        get { CuseMode.restored(from: UserDefaults.standard.string(forKey: "selectedMode")) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "selectedMode") }
    }

    static var hasCompletedOnboarding: Bool {
        get { bool(for: .hasCompletedOnboarding) }
        set { set(newValue, for: .hasCompletedOnboarding) }
    }

    static var hasScreenContentPermission: Bool {
        get { bool(for: .hasScreenContentPermission) }
        set { set(newValue, for: .hasScreenContentPermission) }
    }

    static var hasPreviouslyConfirmedScreenRecordingPermission: Bool {
        get { bool(for: .hasPreviouslyConfirmedScreenRecordingPermission) }
        set { set(newValue, for: .hasPreviouslyConfirmedScreenRecordingPermission) }
    }

    static var isAccurateGroundingEnabled: Bool {
        get { bool(for: .isAccurateGroundingEnabled) }
        set { set(newValue, for: .isAccurateGroundingEnabled) }
    }

    static var isAutopilotEnabled: Bool {
        get { bool(for: .isAutopilotEnabled) }
        set { set(newValue, for: .isAutopilotEnabled) }
    }

    static var isCuaActionDriverEnabled: Bool {
        get { bool(for: .isCuaActionDriverEnabled) }
        set { set(newValue, for: .isCuaActionDriverEnabled) }
    }

    static var isDetectionOverlayEnabled: Bool {
        get { bool(for: .isDetectionOverlayEnabled) }
        set { set(newValue, for: .isDetectionOverlayEnabled) }
    }

    static var isNekoModeEnabled: Bool {
        get { bool(for: .isNekoModeEnabled) }
        set { set(newValue, for: .isNekoModeEnabled) }
    }

    static var isPanelPinned: Bool {
        get { bool(for: .isPanelPinned) }
        set { set(newValue, for: .isPanelPinned) }
    }

    static var isScreenshotStreamingEnabled: Bool {
        get { bool(for: .isScreenshotStreamingEnabled) }
        set { set(newValue, for: .isScreenshotStreamingEnabled) }
    }

    static func reset(_ key: Key) {
        UserDefaults.standard.removeObject(forKey: key.rawValue)
    }

    private static func bool(for key: Key) -> Bool {
        if let storedValue = UserDefaults.standard.object(forKey: key.rawValue) as? Bool {
            return storedValue
        }
        return defaultBool(for: key)
    }

    private static func set(_ value: Bool, for key: Key) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }

    private static func defaultBool(for key: Key) -> Bool {
        switch key {
        case .isAutopilotEnabled, .isCuaActionDriverEnabled, .isScreenshotStreamingEnabled:
            return true
        case .hasCompletedOnboarding,
             .hasScreenContentPermission,
             .hasPreviouslyConfirmedScreenRecordingPermission,
             .isAccurateGroundingEnabled,
             .isDetectionOverlayEnabled,
             .isNekoModeEnabled,
             .isPanelPinned:
            return false
        }
    }

}
