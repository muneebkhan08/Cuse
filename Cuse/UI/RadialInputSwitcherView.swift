//
//  RadialInputSwitcherView.swift
//  Cuse
//
//  Cursor-centered visual switcher for choosing how to give Cuse input.
//

import SwiftUI

enum RadialInputOption: String, CaseIterable, Identifiable {
    case speak
    case type
    case highlight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .speak:
            return "Speak"
        case .type:
            return "Type"
        case .highlight:
            return "Highlight"
        }
    }

    var systemImage: String {
        switch self {
        case .speak:
            return "waveform"
        case .type:
            return "text.cursor"
        case .highlight:
            return "highlighter"
        }
    }

    var offset: CGSize {
        switch self {
        case .speak:
            return CGSize(width: 0, height: -76)
        case .type:
            return CGSize(width: 74, height: 46)
        case .highlight:
            return CGSize(width: -74, height: 46)
        }
    }
}

struct RadialInputSwitcherView: View {
    let highlightedOption: RadialInputOption?

    var body: some View {
        ZStack {
            // The words sit on the same angles the gesture already uses:
            // up is Speak, right is Type, left is Highlight.
            ForEach(RadialInputOption.allCases) { option in
                radialOptionView(option)
                    .offset(option.offset)
            }
        }
        .frame(width: 220, height: 190)
        .allowsHitTesting(false)
        .transition(.scale(scale: 0.86).combined(with: .opacity))
        .animation(.spring(response: 0.18, dampingFraction: 0.82), value: highlightedOption?.id)
    }

    private func radialOptionView(_ option: RadialInputOption) -> some View {
        let isHighlighted = highlightedOption == option
        return Text(option.title)
            .font(DS.Typography.medium(14))
            .foregroundColor(isHighlighted ? DS.Colors.textOnAccent : DS.Colors.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(isHighlighted ? DS.Colors.accent : DS.Colors.background.opacity(0.97))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(isHighlighted ? Color.clear : DS.Colors.borderSubtle, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 4)
    }
}
