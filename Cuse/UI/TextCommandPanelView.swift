import SwiftUI

struct TextCommandPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @FocusState private var isInputFocused: Bool
    @State private var commandText: String = ""

    var body: some View {
        let activityText = companionManager.textCommandActivityText ?? ""
        let hasActivityText = !activityText.isEmpty

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                CusePointerIcon(color: DS.Colors.accent, size: 15)
                    .frame(width: 16, height: 16)

                TextField(companionManager.selectedMode == .combined
                    ? "What should they do?"
                    : "What should Laya do?", text: $commandText)
                    .textFieldStyle(.plain)
                    .font(DS.Typography.regular(15))
                    .tracking(DS.Typography.bodyTracking(for: 15))
                    .foregroundColor(DS.Colors.textPrimary)
                    .tint(DS.Colors.accent)
                    .focused($isInputFocused)
                    .disabled(companionManager.isTextCommandRunning)
                    .onSubmit {
                        submitCommand()
                    }
                    .onExitCommand {
                        commandText = ""
                        companionManager.dismissTextCommandPanel()
                    }
                    .overlay(IBeamCursorView())
                if companionManager.isTextCommandRunning {
                    Button { companionManager.cancelTextCommand() } label: {
                        Image(systemName: "stop.fill")
                            .font(DS.Typography.medium(11))
                            .foregroundColor(DS.Colors.textPrimary)
                            .frame(width: 22, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                                    .fill(DS.Colors.surface2)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("Stop \(companionManager.selectedMode.title)")
                    .accessibilityLabel("Stop \(companionManager.selectedMode.title)")
                }
            }
            .frame(height: 18)

            ZStack(alignment: .leading) {
                TextCommandActivityTicker(
                    text: activityText,
                    isActive: companionManager.isTextCommandRunning
                )
                .opacity(hasActivityText ? 1 : 0)
            }
            .frame(height: 14)
            .clipped()

            // The Jev loop's live decision. The panel is never dismissed on
            // submit (only Escape dismisses it), so this stays on screen for
            // the whole run.
            if let step = companionManager.jevStep {
                JevStepPanelView(snapshot: step)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 380, height: panelHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.background)
                .shadow(color: Color.black.opacity(0.18), radius: 24, x: 0, y: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.16), value: companionManager.textCommandActivityText)
        .animation(.easeInOut(duration: 0.16), value: companionManager.jevStep)
        .preferredColorScheme(.light)
        .onExitCommand { companionManager.dismissTextCommandPanel() }
        .onChange(of: companionManager.isTextCommandRunning) { _, running in
            isInputFocused = !running
        }
        .onChange(of: companionManager.textCommandFocusRequest) { _, _ in
            isInputFocused = false
            DispatchQueue.main.async {
                isInputFocused = !companionManager.isTextCommandRunning
            }
        }
        .onAppear {
            commandText = ""
            DispatchQueue.main.async {
                isInputFocused = true
            }
        }
    }

    private var panelHeight: CGFloat {
        guard let step = companionManager.jevStep else { return TextCommandPanelManager.baseHeight }
        return TextCommandPanelManager.baseHeight + JevStepPanelView.height(for: step)
    }

    private func submitCommand() {
        let trimmedCommand = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { return }
        commandText = ""
        companionManager.submitTextCommand(trimmedCommand)
    }
}

private struct TextCommandActivityTicker: View {
    let text: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(isActive ? DS.Colors.accent : DS.Colors.textTertiary)
                .frame(width: 6, height: 6)

            ZStack(alignment: .leading) {
                Text(text)
                    .id(text)
                    .font(DS.Typography.regular(12))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .transition(
                        .asymmetric(
                            insertion: .opacity,
                            removal: .opacity
                        )
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .padding(.leading, 25)
        .padding(.trailing, 2)
        .accessibilityElement(children: .combine)
    }
}
