import SwiftUI

struct ProviderSetupView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ModeSelectionView(companionManager: companionManager)
            ProviderKeyCard(mode: companionManager.selectedMode,
                onKeyChanged: companionManager.refreshProviderKeyStatus)
                .id(companionManager.selectedMode)
            Text("Saved on this Mac. Switch any time.")
                .font(DS.Typography.regular(12))
                .foregroundColor(DS.Colors.textSecondary)
        }
    }
}

struct ModeSelectionView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(spacing: 8) {
            ForEach(CuseMode.allCases) { mode in
                Button { companionManager.setSelectedMode(mode) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: mode.systemImage)
                            .font(DS.Typography.medium(13))
                            .frame(width: 18)
                            .foregroundColor(companionManager.selectedMode == mode ? DS.Colors.accent : DS.Colors.textTertiary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(mode.selectionTitle)
                                .font(DS.Typography.medium(14))
                                .tracking(DS.Typography.bodyTracking(for: 14))
                                .foregroundColor(DS.Colors.textPrimary)
                            Text(mode.summary)
                                .font(DS.Typography.regular(12))
                                .foregroundColor(DS.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(mode.shortcut)
                                .font(DS.Typography.medium(11))
                                .tracking(DS.Typography.bodyTracking(for: 11))
                                .foregroundColor(DS.Colors.accent)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: companionManager.selectedMode == mode ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(companionManager.selectedMode == mode ? DS.Colors.accent : DS.Colors.borderStrong)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                            .fill(companionManager.selectedMode == mode ? DS.Colors.accentSubtle : DS.Colors.background)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                            .stroke(companionManager.selectedMode == mode ? DS.Colors.accentBorder : DS.Colors.borderSubtle, lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(companionManager.isTextCommandRunning)
                .accessibilityLabel("Select \(mode.title)")
                .accessibilityValue(companionManager.selectedMode == mode ? "Selected" : "Not selected")
            }
        }
    }
}

struct ProviderKeyCard: View {
    let mode: CuseMode
    var onKeyChanged: () -> Void = {}
    private var title: String {
        switch mode {
        case .jev: return "Laya on this Mac"
        case .combined: return "Gemini key for planning"
        case .gemini: return "Gemini key"
        }
    }
    private var detail: String { mode.privacySummary }
    private var keyName: String { mode.keyName }
    @State private var input = ""
    @State private var hasSavedKey = false
    /// A key exists but was saved by an older build, so it can't be read
    /// without the login password. Pasting it again fixes this for good.
    @State private var savedKeyNeedsRepaste = false
    @State private var status = ""

    var body: some View {
        if mode.requiresAPIKey {
            keyEntry
        } else {
            localModelCard
        }
    }

    private var localModelCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(DS.Typography.medium(15))
                    .tracking(DS.Typography.bodyTracking(for: 15))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Text("On this Mac")
                    .font(DS.Typography.medium(11))
                    .foregroundColor(DS.Colors.success)
            }
            Text(detail)
                .font(DS.Typography.regular(13))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Uses the multilingual checkpoint in Application Support. Nothing to paste.")
                .font(DS.Typography.regular(12))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    private var keyEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(DS.Typography.medium(15))
                    .tracking(DS.Typography.bodyTracking(for: 15))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Text(hasSavedKey ? "Saved" : savedKeyNeedsRepaste ? "Paste again" : "Needed")
                    .font(DS.Typography.medium(11))
                    .foregroundColor(hasSavedKey ? DS.Colors.success : savedKeyNeedsRepaste ? DS.Colors.warning : DS.Colors.textTertiary)
            }
            Text(detail)
                .font(DS.Typography.regular(13))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if savedKeyNeedsRepaste {
                Text("This key was saved by an older Cuse. macOS would ask for your password to release it. Paste it once more and the prompt goes away.")
                    .font(DS.Typography.regular(12))
                    .foregroundColor(DS.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SecureField(hasSavedKey ? "Paste a replacement key" : "Paste your API key", text: $input)
                .textFieldStyle(.plain)
                .dsInputFieldChrome()
                .accessibilityLabel("\(title) API key")
                .onSubmit { save() }
            HStack(spacing: 8) {
                Button("Save key", action: save)
                    .dsPrimaryButtonStyle(isFullWidth: false)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
                Button("Remove") {
                    if KeychainStore.delete(forKey: keyName) {
                        hasSavedKey = false
                        savedKeyNeedsRepaste = false
                        input = ""
                        status = "Removed"
                        onKeyChanged()
                    } else {
                        status = "Could not remove the key. Try again."
                    }
                }
                .dsSecondaryButtonStyle(isFullWidth: false)
                .disabled(!hasSavedKey)
                .opacity(hasSavedKey ? 1 : 0.4)
            }
            if !status.isEmpty {
                Text(status)
                    .font(DS.Typography.regular(12))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            Text("Stored in the macOS Keychain. Nowhere else.")
                .font(DS.Typography.regular(11))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
        .onAppear { refreshSavedKeyStatus() }
    }

    private func refreshSavedKeyStatus() {
        let savedKeyStatus = KeychainStore.status(forKey: keyName)
        hasSavedKey = savedKeyStatus == .readable
        savedKeyNeedsRepaste = savedKeyStatus == .savedByOlderBuild
    }

    private func save() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if KeychainStore.set(trimmed, forKey: keyName) {
            hasSavedKey = true
            savedKeyNeedsRepaste = false
            input = ""
            status = "Saved"
            onKeyChanged()
        } else {
            status = "Could not save to Keychain. Try again."
        }
    }
}
