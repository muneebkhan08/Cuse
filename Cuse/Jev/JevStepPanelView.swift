//  JevStepPanelView.swift
//  The decision, drawn under the Ctrl+K input while the loop runs.
//
//  The panel is a fixed-width floating NSPanel (440pt, 18pt side padding), so
//  there is no GeometryReader here — usable content width is a constant. Bars
//  are sized by an explicit frame, matching MiniAudioGlyph's approach in
//  OverlayWindow.swift rather than introducing a new layout idiom.

import SwiftUI

struct JevStepPanelView: View {
    let snapshot: JevStepSnapshot

    static let contentWidth: CGFloat = 404
    private static let barRowHeight: CGFloat = 15
    private static let barTrackWidth: CGFloat = 150

    /// How much height the results area needs, so the window can grow to match.
    static func height(for snapshot: JevStepSnapshot) -> CGFloat {
        let header: CGFloat = 13
        let gauges: CGFloat = 13
        let bars = CGFloat(snapshot.bars.count) * barRowHeight
        let note: CGFloat = snapshot.note.isEmpty ? 0 : 14
        let gapCount = 2 + snapshot.bars.count + (snapshot.note.isEmpty ? 0 : 1)
        let spacing = CGFloat(gapCount) * 5
        // Include the gap between this view and the command status row.
        return 8 + 1 + header + gauges + bars + note + spacing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("Step \(snapshot.step)")
                    .foregroundColor(DS.Colors.textPrimary)
                Text("· \(snapshot.detected) seen")
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer()
                if snapshot.milliseconds > 0 {
                    Text("\(snapshot.milliseconds) ms")
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Text("\(snapshot.inputTokens) tokens")
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .font(DS.Typography.medium(10))
            .frame(height: 13)

            HStack(spacing: 12) {
                gauge("done", snapshot.done, DS.Colors.success)
                gauge("absent", snapshot.absent, DS.Colors.warning)
            }
            .frame(height: 13)

            ForEach(snapshot.bars) { bar in
                HStack(spacing: 6) {
                    Text(bar.label)
                        .font(bar.isChosen ? DS.Typography.medium(11) : DS.Typography.regular(11))
                        .foregroundColor(bar.isChosen ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: 118, alignment: .leading)

                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(DS.Colors.surface2)
                            .frame(width: Self.barTrackWidth, height: 4)
                        Capsule()
                            .fill(bar.isChosen ? DS.Colors.accent : DS.Colors.secondaryMark.opacity(0.55))
                            .frame(width: max(4, Self.barTrackWidth * bar.probability), height: 4)
                    }

                    Text(String(format: "%.2f", bar.probability))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(bar.isChosen ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                }
                .frame(height: Self.barRowHeight, alignment: .center)
            }

            if !snapshot.note.isEmpty {
                Text(snapshot.note)
                    .font(DS.Typography.regular(11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: 14)
                    .help(snapshot.note)
            }
        }
        .frame(width: Self.contentWidth, alignment: .leading)
        .animation(.easeInOut(duration: 0.16), value: snapshot)
    }

    private func gauge(_ title: String, _ value: Double, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(DS.Typography.medium(10))
                .foregroundColor(DS.Colors.textTertiary)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DS.Colors.surface2)
                    .frame(width: 64, height: 4)
                Capsule()
                    .fill(tint)
                    .frame(width: max(4, 64 * value), height: 4)
            }
            Text(String(format: "%.2f", value))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(DS.Colors.textSecondary)
        }
    }
}
