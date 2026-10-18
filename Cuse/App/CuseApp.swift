//
//  CuseApp.swift
//  Cuse
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import ServiceManagement
import SwiftUI
import Sparkle

@main
struct CuseApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager = CompanionManager()
    private var harnessServer: CuseHarnessServer?
    private var sparkleUpdaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 Cuse: Starting...")
        print("🎯 Cuse: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        CuseDefaults.registerDefaults()

        CuseAnalytics.configure()
        CuseAnalytics.trackAppOpened()

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        menuBarPanelManager?.showPanelIfMenuBarIconIsHidden()
        companionManager.start()
        let harnessServer = CuseHarnessServer(
            cuseEngine: companionManager.cuseEngine,
            activityReporter: { [weak self] activityText in
                self?.companionManager.reportHarnessActivity(activityText)
            },
            startTextCommand: { [weak self] task, modeName in
                guard let self else { return "Cuse is shutting down." }
                let mode: CuseMode
                switch modeName.lowercased() {
                case "laya", "jev": mode = .jev
                case "combined": mode = .combined
                default: return "Unknown mode \"\(modeName)\". Use laya or combined."
                }
                return self.companionManager.startTextCommandFromHarness(task: task, mode: mode)
            },
            textCommandStatus: { [weak self] in
                guard let companionManager = self?.companionManager else { return [:] }
                var status: [String: Any] = [
                    "running": companionManager.isTextCommandRunning,
                    "mode": companionManager.selectedMode == .jev ? "laya" : companionManager.selectedMode.rawValue,
                    "activity": companionManager.textCommandActivityText ?? ""
                ]
                if let step = companionManager.jevStep {
                    status["step"] = ["number": step.step, "action": step.actionKind, "note": step.note, "detected": step.detected]
                }
                if let outcome = companionManager.lastTextCommandOutcome {
                    status["outcome"] = ["ok": outcome.ok, "reason": outcome.reason ?? "", "message": outcome.message, "actions": outcome.steps]
                }
                return status
            }
        )
        harnessServer.start()
        self.harnessServer = harnessServer
        // Auto-open the panel if the user still needs to do something:
        // either they haven't onboarded yet, or permissions were revoked.
        if !companionManager.hasCompletedOnboarding || !companionManager.hasSelectedModeKey || !companionManager.hasSelectedModePermissions {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        registerAsLoginItemIfNeeded()
        // Sparkle auto-update — only kicks in once SUFeedURL and
        // SUPublicEDKey are populated in Info.plist (via the
        // INFOPLIST_KEY_* settings in the project's build settings).
        // Until then this is a no-op so debug builds don't error.
        startSparkleUpdater()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menuBarPanelManager?.showPanelForReopen()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        harnessServer?.stop()
        companionManager.stop()
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("🎯 Cuse: Registered as login item")
            } catch {
                print("⚠️ Cuse: Failed to register as login item: \(error)")
            }
        }
    }

    private func startSparkleUpdater() {
        // Sparkle reads SUFeedURL + SUPublicEDKey from the bundle's
        // Info.plist. If they're missing (e.g. local dev build before
        // Sparkle keys are configured), starting the updater would
        // throw — short-circuit so debug builds run cleanly.
        let infoDict = Bundle.main.infoDictionary
        let hasFeedURL = (infoDict?["SUFeedURL"] as? String)?.isEmpty == false
        let hasPublicKey = (infoDict?["SUPublicEDKey"] as? String)?.isEmpty == false
        guard hasFeedURL && hasPublicKey else {
            print("⚠️ Cuse: Sparkle updater skipped — SUFeedURL or SUPublicEDKey not set in Info.plist (this is fine for local debug builds)")
            return
        }

        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.sparkleUpdaterController = updaterController

        do {
            try updaterController.updater.start()
            print("🎯 Cuse: Sparkle updater started")
        } catch {
            print("⚠️ Cuse: Sparkle updater failed to start: \(error)")
        }
    }
}
