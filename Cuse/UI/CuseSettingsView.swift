import AVFoundation
import SwiftUI

struct CuseSettingsView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var selectedSection: SettingsSection = .models
    private let sidebarWidth: CGFloat = 178
    private let contentMaxWidth: CGFloat = 620

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Rectangle()
                .fill(DS.Colors.borderSubtle)
                .frame(width: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    selectedContent
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 24)
                .frame(maxWidth: contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 700, minHeight: 500)
        .background(DS.Colors.background)
        .preferredColorScheme(.light)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SettingsPointerMark()
                    .fill(DS.Colors.accent)
                    .frame(width: 18, height: 18)

                Text("Cuse")
                    .font(DS.Typography.display(16))
                    .tracking(DS.Typography.displayTracking(for: 16))
                    .foregroundColor(DS.Colors.textPrimary)
            }
            .padding(.bottom, 16)

            ForEach(SettingsSection.allCases) { section in
                sidebarButton(section)
            }

            Spacer()

            Text("\(companionManager.selectedMode.title) is on\n\(companionManager.selectedMode.shortcut) to start")
                .font(DS.Typography.regular(11))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
        .padding(.horizontal, 14)
        .padding(.top, 24)
        .padding(.bottom, 18)
        .frame(width: sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(DS.Colors.surface1)
    }

    private func sidebarButton(_ section: SettingsSection) -> some View {
        Button {
            selectedSection = section
        } label: {
            HStack(spacing: 9) {
                Image(systemName: section.systemImage)
                    .font(DS.Typography.medium(12))
                    .foregroundColor(selectedSection == section ? DS.Colors.accent : DS.Colors.textTertiary)
                    .frame(width: 16)

                Text(section.title)
                    .font(DS.Typography.medium(13))
                    .tracking(DS.Typography.bodyTracking(for: 13))
                    .foregroundColor(selectedSection == section ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(selectedSection == section ? DS.Colors.accentSubtle : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(selectedSection.title)
                .font(DS.Typography.display(24))
                .tracking(DS.Typography.displayTracking(for: 24))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)

            Text(selectedSection.subtitle)
                .font(DS.Typography.regular(14))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedSection {
        case .models:
            voiceSection
        case .connections:
            connectionsSection
        case .privacy:
            privacySection
        case .permissions:
            permissionsSection
        case .advanced:
            advancedSection
        }
    }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProviderSetupView(companionManager: companionManager)
        }
    }

    private var connectionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingsRow(
                title: "Desktop actions",
                subtitle: companionManager.isCuaActionDriverEnabled
                    ? "Clicking, typing, launching, and shortcuts are on."
                    : "Cuse can look and plan. It will not touch the desktop.",
                systemImage: "cursorarrow.motionlines",
                isOn: Binding(
                    get: { companionManager.isCuaActionDriverEnabled },
                    set: { companionManager.setCuaActionDriverEnabled($0) }
                )
            )
        }
        .settingsCardChrome()
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
            settingsRow(
                title: "Screenshots",
                subtitle: companionManager.isScreenshotStreamingEnabled
                    ? "Gemini can see the screen when you ask."
                    : "Pictures stay here. Local grounding can still run.",
                systemImage: companionManager.isScreenshotStreamingEnabled ? "eye" : "eye.slash",
                isOn: Binding(
                    get: { companionManager.isScreenshotStreamingEnabled },
                    set: { companionManager.setScreenshotStreamingEnabled($0) }
                )
            )

            settingsRowDivider
            settingsRow(
                title: "Local grounding",
                subtitle: companionManager.isAccurateGroundingEnabled
                    ? "On-device vision finds the control before any model guesses."
                    : "Use accessibility and the page itself.",
                systemImage: "scope",
                isOn: Binding(
                    get: { companionManager.isAccurateGroundingEnabled },
                    set: { companionManager.setAccurateGroundingEnabled($0) }
                )
            )
            }
            .settingsCardChrome()

            note("Screenshots only controls what leaves the Mac. Cuse still reads the screen locally when grounding is on.")
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if companionManager.selectedMode == .gemini {
            permissionRow(
                title: "Microphone",
                subtitle: "Voice mode only.",
                systemImage: "mic",
                isGranted: companionManager.hasMicrophonePermission
            ) {
                let status = AVCaptureDevice.authorizationStatus(for: .audio)
                if status == .notDetermined {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in }
                } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }

            settingsRowDivider
            }

            permissionRow(
                title: "Accessibility",
                subtitle: "Read controls and move the pointer.",
                systemImage: "hand.raised",
                isGranted: companionManager.hasAccessibilityPermission
            ) {
                WindowPositionManager.requestAccessibilityPermission()
            }

            settingsRowDivider
            permissionRow(
                title: "Screen Recording",
                subtitle: "See the screen you are working on.",
                systemImage: "rectangle.dashed.badge.record",
                isGranted: companionManager.hasScreenRecordingPermission
            ) {
                WindowPositionManager.requestScreenRecordingPermission()
            }

            if companionManager.hasScreenRecordingPermission {
                settingsRowDivider
                permissionRow(
                    title: "Screen Content",
                    subtitle: "Read the screen without picking a window each time.",
                    systemImage: "eye",
                    isGranted: companionManager.hasScreenContentPermission
                ) {
                    companionManager.requestScreenContentPermission()
                }
            }
        }
        .settingsCardChrome()
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingsRow(
                title: "Neko",
                subtitle: "A pixel cat follows the work instead of the pointer.",
                systemImage: "cat.fill",
                isOn: Binding(
                    get: { companionManager.isNekoModeEnabled },
                    set: { companionManager.setNekoModeEnabled($0) }
                )
            )

            #if DEBUG
            settingsRowDivider
            settingsRow(
                title: "Detection overlay",
                subtitle: "Draw the on-device boxes while you debug.",
                systemImage: "viewfinder",
                isOn: Binding(
                    get: { companionManager.isDetectionOverlayEnabled },
                    set: { companionManager.setDetectionOverlayEnabled($0) }
                )
            )

            settingsRowDivider
            Button {
                let screen = NSScreen.main
                companionManager.detectedElementScreenLocation = screen.map {
                    CGPoint(x: $0.frame.midX, y: $0.frame.midY)
                }
                companionManager.detectedElementDisplayFrame = screen?.frame
                companionManager.detectedElementBubbleText = "Test"
            } label: {
                settingsActionLabel(
                    title: "Test the pointer",
                    subtitle: "Send it to the center of the main screen.",
                    systemImage: "arrow.up.right"
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            #endif
        }
        .settingsCardChrome()
    }

    private var settingsRowDivider: some View {
        Rectangle()
            .fill(DS.Colors.borderSubtle)
            .frame(height: 1)
    }

    private func settingsRow(
        title: String,
        subtitle: String,
        systemImage: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            rowIcon(systemImage)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.Typography.medium(14))
                    .tracking(DS.Typography.bodyTracking(for: 14))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(subtitle)
                    .font(DS.Typography.regular(12))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 12)

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(DS.Colors.accent)
                .scaleEffect(0.82)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func permissionRow(
        title: String,
        subtitle: String,
        systemImage: String,
        isGranted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            rowIcon(systemImage)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.Typography.medium(14))
                    .tracking(DS.Typography.bodyTracking(for: 14))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(subtitle)
                    .font(DS.Typography.regular(12))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 12)

            if isGranted {
                HStack(spacing: 5) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Allowed")
                        .font(DS.Typography.medium(12))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button("Allow", action: action)
                    .dsPrimaryButtonStyle(isFullWidth: false)
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsActionLabel(
        title: String,
        subtitle: String,
        systemImage: String
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            rowIcon(systemImage)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.Typography.medium(14))
                    .tracking(DS.Typography.bodyTracking(for: 14))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(subtitle)
                    .font(DS.Typography.regular(12))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func rowIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(DS.Typography.medium(13))
            .foregroundColor(DS.Colors.accent)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.accentSubtle)
            )
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(DS.Typography.regular(12))
            .foregroundColor(DS.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension View {
    /// A white grouped card with a hairline border, holding rows separated by hairlines.
    func settingsCardChrome() -> some View {
        self
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .fill(DS.Colors.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case models
    case connections
    case privacy
    case permissions
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .models: return "Modes"
        case .connections: return "Actions"
        case .privacy: return "Privacy"
        case .permissions: return "Access"
        case .advanced: return "Advanced"
        }
    }

    var subtitle: String {
        switch self {
        case .models:
            return "Laya runs on this Mac. Gemini and Combined share one key."
        case .connections:
            return "What Cuse is allowed to do on the desktop."
        case .privacy:
            return "What can leave this Mac, and how the screen is read."
        case .permissions:
            return "What macOS must allow before Cuse can act."
        case .advanced:
            return "The pointer’s personality, and tools for development."
        }
    }

    var systemImage: String {
        switch self {
        case .models: return "waveform.badge.mic"
        case .connections: return "point.3.connected.trianglepath.dotted"
        case .privacy: return "lock.shield"
        case .permissions: return "checkmark.shield"
        case .advanced: return "slider.horizontal.3"
        }
    }
}

private struct SettingsPointerMark: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let originX = rect.midX - 12 * scale
        let originY = rect.midY - 12 * scale

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: originX + x * scale, y: originY + y * scale)
        }

        var path = Path()
        path.move(to: point(4.037, 4.688))
        path.addCurve(
            to: point(4.688, 4.037),
            control1: point(3.90, 3.90),
            control2: point(3.90, 3.90)
        )
        path.addLine(to: point(20.688, 10.537))
        path.addCurve(
            to: point(20.625, 11.484),
            control1: point(21.42, 10.84),
            control2: point(21.42, 10.84)
        )
        path.addLine(to: point(14.501, 13.064))
        path.addCurve(
            to: point(13.063, 14.499),
            control1: point(13.43, 13.34),
            control2: point(13.43, 13.34)
        )
        path.addLine(to: point(11.484, 20.625))
        path.addCurve(
            to: point(10.537, 20.688),
            control1: point(11.17, 21.42),
            control2: point(11.17, 21.42)
        )
        path.closeSubpath()
        return path
    }
}
