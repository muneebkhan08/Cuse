import Foundation

nonisolated enum CuseMode: String, CaseIterable, Identifiable {
    case jev
    case combined
    case gemini

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jev: return "Laya"
        case .combined: return "Combined"
        case .gemini: return "Gemini"
        }
    }

    /// The label on the mode picker card. The summary underneath names the input style.
    var selectionTitle: String {
        switch self {
        case .jev: return "Laya"
        case .combined: return "Combined"
        case .gemini: return "Gemini"
        }
    }

    /// Combined mode plans with Gemini Flash, so it shares Gemini's Keychain key.
    var keyName: String { self == .jev ? "jevAPIKey" : "geminiAPIKey" }

    /// Text mode runs the local multilingual checkpoint. Gemini and Combined need Gemini's key.
    var requiresAPIKey: Bool { self != .jev }

    /// Laya and Combined both run from the text command panel, on different shortcuts.
    var usesTextCommandPanel: Bool { self != .gemini }

    var shortcut: String {
        switch self {
        case .jev: return "Ctrl+K"
        case .combined: return "Ctrl+L"
        case .gemini: return "Ctrl+Option"
        }
    }

    var systemImage: String {
        switch self {
        case .jev: return "text.cursor"
        case .combined: return "sparkles"
        case .gemini: return "waveform"
        }
    }

    var summary: String {
        switch self {
        case .jev: return "Type a task. Laya finds the control and clicks it, on this Mac."
        case .combined: return "Type a task. Gemini plans the step. Laya moves the pointer and clicks."
        case .gemini: return "Talk. Gemini clicks, types, and shows you the way."
        }
    }

    var privacySummary: String {
        switch self {
        case .jev:
            return "The task and the labels stay on this Mac. Laya picks the control here. Images never leave."
        case .combined:
            return "The task and the labels go to Google. A screenshot is added only when labels are not enough, and only if Screenshots is on."
        case .gemini:
            return "Your voice goes to Google. Screenshots go only if you turn them on."
        }
    }

    static func restored(from value: String?) -> Self {
        value.flatMap(Self.init(rawValue:)) ?? .jev
    }

    /// Only voice mode needs the microphone.
    func permissionsReady(desktop: Bool, microphone: Bool) -> Bool {
        desktop && (self != .gemini || microphone)
    }
}
