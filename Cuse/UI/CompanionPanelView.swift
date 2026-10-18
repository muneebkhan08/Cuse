//
//  CompanionPanelView.swift
//  Cuse
//
//  SwiftUI content hosted inside the menu bar panel. The normal surface is
//  intentionally pointer-first; durable configuration lives in the separate
//  Settings window.
//  Light panel: white header and body, soft-gray footer, one indigo accent.
//

import AVFoundation
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var setupStep: SetupStep = .mode

    private enum SetupStep: Int {
        case mode = 1, key, permissions
    }

    private var isReady: Bool {
        companionManager.hasCompletedOnboarding && companionManager.hasSelectedModeKey
            && companionManager.hasSelectedModePermissions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader

            VStack(alignment: .leading, spacing: 16) {
                if isReady {
                    primaryMessageSection
                    readyControlSection
                } else {
                    onboardingSection
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Colors.background)

            footerSection
        }
        .frame(width: 360)
        .background(DS.Colors.background)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 28, x: 0, y: 16)
        .shadow(color: Color.black.opacity(0.06), radius: 1, x: 0, y: 1)
        .preferredColorScheme(.light)
        .onAppear {
            companionManager.refreshProviderKeyStatus()
            if companionManager.hasCompletedOnboarding {
                setupStep = companionManager.hasSelectedModeKey ? .permissions : .key
            }
        }
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack(spacing: 8) {
            CusePointerIcon(color: DS.Colors.accent, size: 16)

            Text("Cuse")
                .font(DS.Typography.display(15))
                .tracking(DS.Typography.displayTracking(for: 15))
                .foregroundColor(DS.Colors.textPrimary)

            Spacer()

            statusBadge

            pinToggleButton

            Button(action: {
                NotificationCenter.default.post(name: .cuseDismissPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(DS.Typography.medium(10))
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                            .fill(DS.Colors.surface1)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(DS.Colors.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DS.Colors.borderSubtle)
                .frame(height: 1)
        }
    }

    /// Status as a small pill: a dot and a word. The dot is green when ready or
    /// working, amber during setup, and gray otherwise.
    private var statusBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(DS.Typography.medium(11))
                .foregroundColor(DS.Colors.textSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(DS.Colors.surface1)
        )
    }

    private var statusDotColor: Color {
        if !isReady { return DS.Colors.warning }
        return companionManager.voiceState == .idle && !companionManager.isTextCommandRunning
            ? DS.Colors.success
            : DS.Colors.accent
    }

    /// Pushpin toggle. When on, the panel stays visible regardless of
    /// outside clicks. When off (default), the panel behaves like a
    /// standard menu bar popover.
    private var pinToggleButton: some View {
        Button(action: {
            companionManager.setPanelPinned(!companionManager.isPanelPinned)
        }) {
            Image(systemName: companionManager.isPanelPinned ? "pin.fill" : "pin")
                .font(DS.Typography.medium(10))
                .foregroundColor(
                    companionManager.isPanelPinned
                        ? DS.Colors.accent
                        : DS.Colors.textSecondary
                )
                .rotationEffect(.degrees(companionManager.isPanelPinned ? 0 : 45))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .fill(
                            companionManager.isPanelPinned
                                ? DS.Colors.accentSubtle
                                : DS.Colors.surface1
                        )
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(companionManager.isPanelPinned
            ? "Unpin: panel will close when you click outside"
            : "Pin: panel will stay open when you click outside")
    }

    // MARK: - Primary Message

    private var primaryMessageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(companionManager.selectedMode.title.uppercased())
                .font(DS.Typography.medium(10))
                .tracking(DS.Typography.labelTracking(for: 10))
                .foregroundColor(DS.Colors.accent)
            Text("\(companionManager.selectedMode.title) is on")
                .font(DS.Typography.display(20))
                .tracking(DS.Typography.displayTracking(for: 20))
                .foregroundColor(DS.Colors.textPrimary)
            Text(companionManager.selectedMode.summary)
                .font(DS.Typography.regular(13))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: companionManager.openSelectedMode) {
                Text(primaryActionTitle)
                    .frame(maxWidth: .infinity)
            }
            .dsPrimaryButtonStyle()
            .disabled(companionManager.isTextCommandRunning)
            .opacity(companionManager.isTextCommandRunning ? 0.45 : 1)
        }
    }

    private var primaryActionTitle: String {
        if companionManager.selectedMode.usesTextCommandPanel {
            return "Open \(companionManager.selectedMode.title)  ·  \(companionManager.selectedMode.shortcut)"
        }
        let voiceTitle = companionManager.voiceState == .idle ? "Start voice" : "Stop voice"
        return "\(voiceTitle)  ·  \(companionManager.selectedMode.shortcut)"
    }

    private var permissionsExplanationForSelectedMode: String {
        switch companionManager.selectedMode {
        case .jev:
            return "Laya sees the controls on this Mac and clicks them. No microphone. No API key."
        case .combined:
            return "Combined sees the controls and clicks them. No microphone."
        case .gemini:
            return "Gemini needs the desktop, and the microphone, so you can talk."
        }
    }

    private var onboardingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("STEP \(setupStep.rawValue) OF 3")
                    .font(DS.Typography.medium(10))
                    .tracking(DS.Typography.labelTracking(for: 10))
                    .foregroundColor(DS.Colors.accent)
                Text(setupStep == .mode ? "How should Cuse act?" : setupStep == .key ? "Connect \(companionManager.selectedMode.title)" : "Allow the desktop")
                    .font(DS.Typography.display(20))
                    .tracking(DS.Typography.displayTracking(for: 20))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch setupStep {
            case .mode:
                ModeSelectionView(companionManager: companionManager)
                Text("Laya is the default. It runs on this Mac, with no key. Switch any time in Settings.")
                    .font(DS.Typography.regular(12))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .key:
                ProviderKeyCard(mode: companionManager.selectedMode,
                    onKeyChanged: companionManager.refreshProviderKeyStatus)
                    .id(companionManager.selectedMode)
            case .permissions:
                Text(permissionsExplanationForSelectedMode)
                    .font(DS.Typography.regular(13))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                permissionsListSection
            }

            HStack {
                if setupStep != .mode {
                    Button("Back") {
                        setupStep = setupStep == .permissions ? .key : .mode
                    }
                    .dsTextButtonStyle(fontSize: 13)
                }
                Spacer()
                Button(setupStep == .permissions ? "Start with \(companionManager.selectedMode.title)" : "Continue") {
                    switch setupStep {
                    case .mode: setupStep = .key
                    case .key: setupStep = .permissions
                    case .permissions: companionManager.triggerOnboarding()
                    }
                }
                .dsPrimaryButtonStyle(isFullWidth: false)
                .disabled((setupStep == .key && !companionManager.hasSelectedModeKey)
                    || (setupStep == .permissions && (!companionManager.hasSelectedModeKey || !companionManager.hasSelectedModePermissions)))
                .opacity((setupStep == .key && !companionManager.hasSelectedModeKey)
                    || (setupStep == .permissions && (!companionManager.hasSelectedModeKey || !companionManager.hasSelectedModePermissions)) ? 0.4 : 1)
            }
        }
    }

    // MARK: - Ready Controls

    private var readyControlSection: some View {
        VStack(spacing: 8) {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ],
                spacing: 8
            ) {
                compactControlButton(
                    title: companionManager.isAutopilotEnabled ? "Auto-click" : "Point only",
                    subtitle: companionManager.isAutopilotEnabled ? "acts" : "guides",
                    systemImage: companionManager.isAutopilotEnabled ? "wand.and.stars" : "hand.tap",
                    isActive: companionManager.isAutopilotEnabled,
                    helpText: companionManager.isAutopilotEnabled
                        ? "Cuse clicks and types after grounding one action"
                        : "Cuse points at the target and waits for you"
                ) {
                    companionManager.setAutopilotEnabled(!companionManager.isAutopilotEnabled)
                }

                compactControlButton(
                    title: companionManager.isAccurateGroundingEnabled ? "Local" : "AX/DOM",
                    subtitle: "grounding",
                    systemImage: "scope",
                    isActive: companionManager.isAccurateGroundingEnabled,
                    helpText: "Toggle local YOLO/OCR grounding"
                ) {
                    companionManager.setAccurateGroundingEnabled(!companionManager.isAccurateGroundingEnabled)
                }

                // Combined mode also sends a screenshot when labels are not enough.
                if companionManager.selectedMode != .jev {
                compactControlButton(
                    title: companionManager.isScreenshotStreamingEnabled ? "Screens" : "Private",
                    subtitle: companionManager.isScreenshotStreamingEnabled ? "remote" : "local",
                    systemImage: companionManager.isScreenshotStreamingEnabled ? "eye" : "eye.slash",
                    isActive: companionManager.isScreenshotStreamingEnabled,
                    helpText: "Toggle remote screenshot context"
                ) {
                    companionManager.setScreenshotStreamingEnabled(!companionManager.isScreenshotStreamingEnabled)
                }
                }

            }

            if let activityText = companionManager.textCommandActivityText, !activityText.isEmpty {
                HStack(spacing: 6) {
                    if companionManager.isTextCommandRunning {
                        ProgressView().controlSize(.small).scaleEffect(0.55)
                    }
                    Text(activityText)
                        .font(DS.Typography.regular(11))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
            }
        }
    }

    private func compactControlButton(
        title: String,
        subtitle: String,
        systemImage: String,
        isActive: Bool,
        helpText: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(DS.Typography.medium(12))
                    .foregroundColor(isActive ? DS.Colors.accent : DS.Colors.textTertiary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(DS.Typography.medium(12))
                        .tracking(DS.Typography.bodyTracking(for: 12))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(DS.Typography.regular(10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(isActive ? DS.Colors.accentSubtle : DS.Colors.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(isActive ? DS.Colors.accentBorder : DS.Colors.borderSubtle, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(helpText)
    }

    // MARK: - Permissions List

    private var permissionsListSection: some View {
        VStack(spacing: 2) {
            Text("ACCESS")
                .font(DS.Typography.medium(10))
                .tracking(DS.Typography.labelTracking(for: 10))
                .foregroundColor(DS.Colors.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)

            if companionManager.selectedMode == .gemini { microphonePermissionRow }
            accessibilityPermissionRow
            screenRecordingPermissionRow

            if companionManager.hasScreenRecordingPermission {
                screenContentPermissionRow
            }


        }
    }

    private var accessibilityPermissionRow: some View {
        let isGranted = companionManager.hasAccessibilityPermission
        return HStack(alignment: .top) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(DS.Typography.medium(12))
                    .foregroundColor(isGranted ? DS.Colors.success : DS.Colors.warning)
                    .frame(width: 16)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Accessibility")
                        .font(DS.Typography.medium(13))
                        .tracking(DS.Typography.bodyTracking(for: 13))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Move the pointer and read the screen.")
                        .font(DS.Typography.regular(11))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            if isGranted {
                grantedPill
            } else {
                HStack(spacing: 6) {
                    grantButton {
                        WindowPositionManager.requestAccessibilityPermission()
                    }
                    Button(action: {
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                    }) {
                        Text("Find app")
                            .font(DS.Typography.medium(11))
                            .foregroundColor(DS.Colors.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                                    .fill(DS.Colors.surface2)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var screenRecordingPermissionRow: some View {
        let isGranted = companionManager.hasScreenRecordingPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(DS.Typography.medium(12))
                    .foregroundColor(isGranted ? DS.Colors.success : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Screen Recording")
                        .font(DS.Typography.medium(13))
                        .tracking(DS.Typography.bodyTracking(for: 13))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(isGranted
                         ? "See the screen when you ask."
                         : "Quit and reopen after you allow it.")
                        .font(DS.Typography.regular(11))
                        .foregroundColor(DS.Colors.textSecondary)
                }
            }

            Spacer()

            if isGranted {
                grantedPill
            } else {
                grantButton {
                    WindowPositionManager.requestScreenRecordingPermission()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var screenContentPermissionRow: some View {
        let isGranted = companionManager.hasScreenContentPermission
        return HStack(alignment: .top) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "eye")
                    .font(DS.Typography.medium(12))
                    .foregroundColor(isGranted ? DS.Colors.success : DS.Colors.warning)
                    .frame(width: 16)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Screen Content")
                        .font(DS.Typography.medium(13))
                        .tracking(DS.Typography.bodyTracking(for: 13))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Read the screen without picking a window each time.")
                        .font(DS.Typography.regular(11))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            if isGranted {
                grantedPill
            } else {
                grantButton {
                    companionManager.requestScreenContentPermission()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var microphonePermissionRow: some View {
        let isGranted = companionManager.hasMicrophonePermission
        return HStack(alignment: .top) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "mic")
                    .font(DS.Typography.medium(12))
                    .foregroundColor(isGranted ? DS.Colors.success : DS.Colors.warning)
                    .frame(width: 16)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Microphone")
                        .font(DS.Typography.medium(13))
                        .tracking(DS.Typography.bodyTracking(for: 13))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Voice only. Hold ⌃⌥ and talk.")
                        .font(DS.Typography.regular(11))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            if isGranted {
                grantedPill
            } else {
                grantButton {
                    let status = AVCaptureDevice.authorizationStatus(for: .audio)
                    if status == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var grantedPill: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(DS.Colors.success)
                .frame(width: 6, height: 6)
            Text("Allowed")
                .font(DS.Typography.medium(11))
                .foregroundColor(DS.Colors.success)
        }
    }

    private func grantButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Allow")
                .font(DS.Typography.medium(11))
                .tracking(DS.Typography.bodyTracking(for: 11))
                .foregroundColor(DS.Colors.textOnAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .fill(DS.Colors.accent)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var footerSection: some View {
        HStack(spacing: 4) {
            footerTextButton("Settings") {
                NotificationCenter.default.post(name: .cuseOpenSettings, object: nil)
                NotificationCenter.default.post(name: .cuseDismissPanel, object: nil)
            }

            footerTextButton("Logs") {
                PipelineLogStore.shared.record(
                    category: "ui",
                    name: "open_logs_window",
                    status: "ok",
                    message: "Opened Cuse logs window."
                )
                NotificationCenter.default.post(name: .cuseOpenLogs, object: nil)
                NotificationCenter.default.post(name: .cuseDismissPanel, object: nil)
            }

            Spacer()

            footerTextButton("Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(DS.Colors.surface1)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DS.Colors.borderSubtle)
                .frame(height: 1)
        }
    }

    private func footerTextButton(
        _ title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(DS.Typography.medium(12))
                .tracking(DS.Typography.bodyTracking(for: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Visuals

    private var statusText: String {
        if !isReady {
            return "Setup"
        }
        if !companionManager.isOverlayVisible {
            return "Ready"
        }
        switch companionManager.voiceState {
        case .idle:
            return "On"
        case .listening:
            return "Listening"
        case .processing:
            return "Thinking"
        case .responding:
            return "Speaking"
        }
    }
}
