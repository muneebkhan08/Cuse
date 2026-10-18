//
//  DesignSystem.swift
//  Cuse
//
//  Cuse's design system. A light, native-feeling macOS look: white
//  surfaces, soft gray fills, hairline borders, system typography and one
//  indigo accent. Every text/background pairing below was checked against
//  WCAG AA (4.5:1) — the measured ratios are noted beside each token.
//  Text fields use the I-beam; controls use the pointing hand. See design.md.
//

import SwiftUI
import AppKit

// MARK: - Design System Namespace

/// The top-level namespace for all design system tokens.
/// Usage: `DS.Colors.background`, `DS.Colors.accent`, etc.
enum DS {

    // MARK: - Color Tokens

    enum Colors {

        // ── Surfaces ─────────────────────────────────────────────────

        /// Window and panel field.
        static let background = Color(hex: "#FFFFFF")

        /// Subtle fill for inputs, rows, the sidebar and footers.
        static let surface1 = Color(hex: "#F5F5F7")

        /// Hover fill.
        static let surface2 = Color(hex: "#EDEDF0")

        /// Pressed fill.
        static let surface3 = Color(hex: "#E4E4E9")

        /// Strongest neutral fill, used for tracks and disabled controls.
        static let surface4 = Color(hex: "#D9D9E0")

        /// Hairline between rows and around cards.
        static let borderSubtle = Color(hex: "#E2E2E8")

        /// Border on hover and for emphasised controls.
        static let borderStrong = Color(hex: "#C7C7D1")

        // ── Text ─────────────────────────────────────────────────────

        /// Titles and body. 16.8:1 on white, 15.5:1 on surface1.
        static let textPrimary = Color(hex: "#1D1D1F")

        /// Supporting sentences. 7.4:1 on white, 6.8:1 on surface1.
        static let textSecondary = Color(hex: "#55555F")

        /// Captions, shortcuts, idle words. 5.3:1 on white, 4.8:1 on surface1.
        static let textTertiary = Color(hex: "#6B6B76")

        /// Type and icons that sit on an accent fill. 6.3:1 on accent.
        static let textOnAccent = Color(hex: "#FFFFFF")

        // ── Accent (indigo) ──────────────────────────────────────────

        /// The one brand color. 6.3:1 against white, in either direction.
        static let accent = Color(hex: "#4F46E5")

        /// Hover. White type on it is 7.9:1.
        static let accentHover = Color(hex: "#4338CA")

        /// Pressed. White type on it is 9.9:1.
        static let accentPressed = Color(hex: "#3730A3")

        /// Accent used as text on a light surface.
        static let accentText = accent

        /// A quiet accent wash for selected rows and active toggles.
        static let accentSubtle = Color(hex: "#EEF0FF")

        /// Border for a selected, accent-washed control.
        static let accentBorder = Color(hex: "#C7CBFA")

        /// A second mark that must differ from the accent, such as a detected
        /// text box that is not the chosen target. 5.4:1 on white.
        static let secondaryMark = Color(hex: "#0E7490")

        // ── Status ───────────────────────────────────────────────────

        /// Granted, saved, done. 5.0:1 on white.
        static let success = Color(hex: "#15803D")

        /// Needs attention. 5.0:1 on white.
        static let warning = Color(hex: "#B45309")
        static let warningText = warning

        /// Destructive fill. White type on it is 4.8:1.
        static let destructive = Color(hex: "#DC2626")
        static let destructiveHover = Color(hex: "#B91C1C")

        /// Destructive as text on a light surface. 6.5:1 on white.
        static let destructiveText = Color(hex: "#B91C1C")

        // ── On-screen pointer ────────────────────────────────────────

        /// The pointer's edge and glow. The arrow itself is filled white, so
        /// the shape reads on both light and dark desktops.
        static let overlayCursor = accent

        /// Fill of the on-screen pointer arrow.
        static let overlayCursorFill = Color(hex: "#FFFFFF")

        // ── Disabled State ───────────────────────────────────────────
        // Following Material Design 3's disabled pattern:
        // Container: onSurface at 12% opacity
        // Content: onSurface at 38% opacity

        /// Disabled button/container background.
        static var disabledBackground: Color {
            textPrimary.opacity(0.12)
        }

        /// Disabled text/icon color.
        static var disabledText: Color {
            textPrimary.opacity(0.38)
        }
    }

    // MARK: - Spacing (for reference, not enforced)

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    // MARK: - Corner Radii

    enum CornerRadius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 8
        static let large: CGFloat = 12
        static let extraLarge: CGFloat = 14
        static let pill: CGFloat = .infinity
    }

    // MARK: - Type

    /// The macOS system font (SF Pro). Titles are semibold, controls medium,
    /// supporting text regular. Small uppercase labels get light tracking.
    enum Typography {
        static func display(_ size: CGFloat) -> Font {
            .system(size: size, weight: .semibold)
        }

        static func medium(_ size: CGFloat) -> Font {
            .system(size: size, weight: .medium)
        }

        static func regular(_ size: CGFloat) -> Font {
            .system(size: size, weight: .regular)
        }

        static func italic(_ size: CGFloat) -> Font {
            .system(size: size, weight: .regular)
        }

        static func displayTracking(for size: CGFloat) -> CGFloat {
            size * -0.012
        }

        static func bodyTracking(for size: CGFloat) -> CGFloat {
            0
        }

        /// Light tracking for short uppercase labels, in points.
        static func labelTracking(for size: CGFloat) -> CGFloat {
            size * 0.06
        }
    }

    // MARK: - Animation Durations

    enum Animation {
        /// Quick state changes — hover in/out, press feedback.
        static let fast: Double = 0.15
        /// Standard transitions — content reveal, button state changes.
        static let normal: Double = 0.25
        /// Slower, more dramatic — fade-ins, celebration screen elements.
        static let slow: Double = 0.4
    }

    // MARK: - State Layer Opacities
    // Based on Material Design 3's state layer system.
    // A "state layer" overlays the button's content color at these opacities.

    enum StateLayer {
        /// Hover: subtle highlight to indicate interactivity.
        static let hover: Double = 0.08
        /// Focus: keyboard navigation indicator (slightly stronger than hover).
        static let focus: Double = 0.12
        /// Pressed: active press feedback (same strength as focus).
        static let pressed: Double = 0.12
        /// Dragged: strongest overlay (rarely used).
        static let dragged: Double = 0.16
    }
}

// MARK: - Button Styles

/// Primary button. Accent fill, white type. One per view.
struct DSPrimaryButtonStyle: ButtonStyle {
    var isFullWidth: Bool = true

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Typography.medium(14))
            .tracking(DS.Typography.bodyTracking(for: 14))
            .foregroundColor(DS.Colors.textOnAccent)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .padding(.vertical, 11)
            .padding(.horizontal, isFullWidth ? 0 : 16)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .overlay(PointerCursorView())
            .onHover { hovering in
                isHovered = hovering
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.accentPressed
        } else if isHovered {
            return DS.Colors.accentHover
        } else {
            return DS.Colors.accent
        }
    }
}

/// Secondary button — supporting actions, less visual weight than primary.
/// Surface-colored background with primary text. Used for: action buttons
/// (download, open link), embedded element buttons.
struct DSSecondaryButtonStyle: ButtonStyle {
    var isFullWidth: Bool = true

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Typography.medium(14))
            .tracking(DS.Typography.bodyTracking(for: 14))
            .foregroundColor(DS.Colors.textPrimary)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .padding(.vertical, 11)
            .padding(.horizontal, isFullWidth ? 0 : 16)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .overlay(PointerCursorView())
            .onHover { hovering in
                isHovered = hovering
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.surface4
        } else if isHovered {
            return DS.Colors.surface3
        } else {
            return DS.Colors.surface2
        }
    }
}

/// Tertiary/ghost button — low-emphasis actions with subtle hover background.
/// Transparent at rest, shows surface fill on hover. Used for: navigation
/// links, sidebar items, medium-low emphasis actions.
struct DSTertiaryButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Typography.medium(14))
            .tracking(DS.Typography.bodyTracking(for: 14))
            .foregroundColor(
                configuration.isPressed
                    ? DS.Colors.textPrimary
                    : isHovered
                        ? DS.Colors.textPrimary
                        : DS.Colors.textSecondary
            )
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .overlay(PointerCursorView())
            .onHover { hovering in
                isHovered = hovering
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.surface3
        } else if isHovered {
            return DS.Colors.surface2
        } else {
            return Color.clear
        }
    }
}

/// Text button — the lowest-emphasis button style. No background on any
/// state, not even hover. Only the text color changes. Used for: "restart",
/// "skip", "cancel", and other truly minimal inline actions where a
/// background would add too much visual weight.
struct DSTextButtonStyle: ButtonStyle {
    var fontSize: CGFloat = 14

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Typography.medium(fontSize))
            .tracking(DS.Typography.bodyTracking(for: fontSize))
            .foregroundColor(
                configuration.isPressed
                    ? DS.Colors.textPrimary
                    : isHovered
                        ? DS.Colors.textPrimary
                        : DS.Colors.textTertiary
            )
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .overlay(PointerCursorView())
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

/// Outlined button — medium emphasis, used where a border helps define
/// the button's bounds. Used for: display selector, copy prompt.
struct DSOutlinedButtonStyle: ButtonStyle {
    var isFullWidth: Bool = true

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Typography.medium(14))
            .tracking(DS.Typography.bodyTracking(for: 14))
            .foregroundColor(DS.Colors.textPrimary)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .padding(.vertical, 11)
            .padding(.horizontal, isFullWidth ? 0 : 16)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(
                        borderColor(isPressed: configuration.isPressed),
                        lineWidth: 1
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .overlay(PointerCursorView())
            .onHover { hovering in
                isHovered = hovering
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.surface3
        } else if isHovered {
            return DS.Colors.surface2
        } else {
            return DS.Colors.surface1
        }
    }

    private func borderColor(isPressed: Bool) -> Color {
        if isPressed || isHovered {
            return DS.Colors.borderStrong
        } else {
            return DS.Colors.borderSubtle
        }
    }
}

/// Destructive button — for dangerous/irreversible actions (close session, delete).
/// Red-tinted background that intensifies on hover and press.
struct DSDestructiveButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Typography.medium(14))
            .tracking(DS.Typography.bodyTracking(for: 14))
            .foregroundColor(DS.Colors.destructiveText)
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(
                        borderColor(isPressed: configuration.isPressed),
                        lineWidth: 1
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .overlay(PointerCursorView())
            .onHover { hovering in
                isHovered = hovering
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.destructive.opacity(0.22)
        } else if isHovered {
            return DS.Colors.destructive.opacity(0.14)
        } else {
            return DS.Colors.destructive.opacity(0.08)
        }
    }

    private func borderColor(isPressed: Bool) -> Color {
        if isPressed || isHovered {
            return DS.Colors.destructive.opacity(0.40)
        } else {
            return DS.Colors.destructive.opacity(0.15)
        }
    }
}

/// Icon-only button — compact circular button for utility actions.
/// Used for: close button (x), send message, small toolbar actions.
struct DSIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var isDestructiveOnHover: Bool = false
    var tooltipText: String? = nil

    /// Controls horizontal alignment of the tooltip relative to the button.
    /// Use `.leading` for buttons near the left edge of the window (tooltip extends right),
    /// `.trailing` for buttons near the right edge (tooltip extends left),
    /// and `.center` for buttons in the middle.
    var tooltipAlignment: Alignment = .center

    @State private var isHovered = false
    @State private var isTooltipVisible = false
    @State private var tooltipShowWorkItem: DispatchWorkItem? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Typography.medium(size * 0.42))
            .foregroundColor(iconColor(isPressed: configuration.isPressed))
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(circleBackgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .stroke(circleBorderColor(isPressed: configuration.isPressed), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .contentShape(Circle())
            // Cursor change via AppKit cursor rects — more reliable than NSCursor.push/pop
            // because cursor rects are managed at the window level and don't conflict
            // with SwiftUI's internal cursor handling.
            .overlay(PointerCursorView())
            .onHover { hovering in
                isHovered = hovering
                // Show the tooltip after a delay (like native tooltips), hide immediately
                tooltipShowWorkItem?.cancel()
                if hovering {
                    let workItem = DispatchWorkItem {
                        withAnimation(.easeOut(duration: 0.15)) {
                            isTooltipVisible = true
                        }
                    }
                    tooltipShowWorkItem = workItem
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: workItem)
                } else {
                    withAnimation(.easeOut(duration: 0.1)) {
                        isTooltipVisible = false
                    }
                }
            }
            // Custom styled tooltip — positioned above the button with enough gap
            // to not overlap the button. Horizontally aligned based on tooltipAlignment
            // so tooltips near window edges don't clip outside the visible area.
            // Uses .allowsHitTesting(false) so the tooltip doesn't interfere
            // with the button's hover state.
            .overlay(
                Group {
                    if isTooltipVisible, let text = tooltipText, !text.isEmpty {
                        Text(text)
                            .font(DS.Typography.medium(11))
                            .tracking(DS.Typography.bodyTracking(for: 11))
                            .foregroundColor(DS.Colors.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(DS.Colors.surface1)
                            )
                            .overlay(
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(DS.Colors.borderSubtle, lineWidth: 1)

                                    RoundedRectangle(cornerRadius: 6)
                                        .trim(from: 0, to: 0.5)
                                        .stroke(
                                            LinearGradient(
                                                colors: [
                                                    Color.white.opacity(0.10),
                                                    Color.white.opacity(0.02)
                                                ],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            ),
                                            lineWidth: 0.8
                                        )
                                }
                            )
                            .shadow(color: Color.black.opacity(0.42), radius: 14, x: 0, y: 8)
                            .shadow(color: Color.black.opacity(0.26), radius: 4, x: 0, y: 2)
                            .fixedSize()
                            .offset(y: -(size / 2 + 20))
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                },
                alignment: tooltipAlignment
            )
    }

    private func iconColor(isPressed: Bool) -> Color {
        if isDestructiveOnHover && (isHovered || isPressed) {
            return DS.Colors.destructiveText
        }
        if isPressed {
            return DS.Colors.textPrimary
        } else if isHovered {
            return DS.Colors.textPrimary
        } else {
            return DS.Colors.textSecondary
        }
    }

    private func circleBackgroundColor(isPressed: Bool) -> Color {
        if isDestructiveOnHover {
            if isPressed {
                return DS.Colors.destructive.opacity(0.22)
            } else if isHovered {
                return DS.Colors.destructive.opacity(0.14)
            } else {
                return DS.Colors.surface2
            }
        }
        if isPressed {
            return DS.Colors.surface4
        } else if isHovered {
            return DS.Colors.surface3
        } else {
            return DS.Colors.surface2
        }
    }

    private func circleBorderColor(isPressed: Bool) -> Color {
        if isDestructiveOnHover && (isHovered || isPressed) {
            return DS.Colors.destructive.opacity(0.30)
        }
        if isPressed || isHovered {
            return DS.Colors.borderStrong
        } else {
            return DS.Colors.borderSubtle.opacity(0.5)
        }
    }
}

// MARK: - Convenience View Extensions

extension View {
    /// Applies the primary button style (accent fill, white type).
    func dsPrimaryButtonStyle(isFullWidth: Bool = true) -> some View {
        self.buttonStyle(DSPrimaryButtonStyle(isFullWidth: isFullWidth))
    }

    /// Applies the secondary button style (surface-colored supporting action).
    func dsSecondaryButtonStyle(isFullWidth: Bool = true) -> some View {
        self.buttonStyle(DSSecondaryButtonStyle(isFullWidth: isFullWidth))
    }

    /// Applies the tertiary/ghost button style (subtle hover background).
    func dsTertiaryButtonStyle() -> some View {
        self.buttonStyle(DSTertiaryButtonStyle())
    }

    /// Applies the text-only button style (no background ever, just color change).
    func dsTextButtonStyle(fontSize: CGFloat = 14) -> some View {
        self.buttonStyle(DSTextButtonStyle(fontSize: fontSize))
    }

    /// Applies the outlined button style (bordered, medium emphasis).
    func dsOutlinedButtonStyle(isFullWidth: Bool = true) -> some View {
        self.buttonStyle(DSOutlinedButtonStyle(isFullWidth: isFullWidth))
    }

    /// Applies the destructive button style (red-tinted danger action).
    func dsDestructiveButtonStyle() -> some View {
        self.buttonStyle(DSDestructiveButtonStyle())
    }

    /// Applies the icon-only button style (compact circle).
    /// `tooltipAlignment` controls where the tooltip sits horizontally relative to the button:
    /// `.leading` for left-edge buttons, `.trailing` for right-edge buttons, `.center` for middle.
    func dsIconButtonStyle(size: CGFloat = 28, isDestructiveOnHover: Bool = false, tooltip: String? = nil, tooltipAlignment: Alignment = .center) -> some View {
        self.buttonStyle(DSIconButtonStyle(size: size, isDestructiveOnHover: isDestructiveOnHover, tooltipText: tooltip, tooltipAlignment: tooltipAlignment))
    }

    /// Attaches the shared pointing-hand cursor treatment used across interactive controls.
    /// Disabled controls can opt out so they keep the default arrow cursor.
    func pointerCursor(isEnabled: Bool = true) -> some View {
        self.overlay {
            if isEnabled {
                PointerCursorView()
            }
        }
    }
}

extension View {
    /// A floating label drawn over the user's desktop: near-opaque white card,
    /// hairline border and a soft shadow so it reads on light and dark wallpapers.
    func dsOverlayLabelChrome() -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.background.opacity(0.97))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 4)
    }

    /// Rounded text field: white fill, hairline border, I-beam cursor. White so it
    /// stays visible on both white and soft-gray cards.
    func dsInputFieldChrome() -> some View {
        self
            .font(DS.Typography.regular(13))
            .foregroundColor(DS.Colors.textPrimary)
            .tint(DS.Colors.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
            .overlay(IBeamCursorView())
    }
}

// MARK: - Pointer Cursor (AppKit Bridge)

/// Uses AppKit's cursor rect system to reliably show a pointing hand cursor.
/// More reliable than NSCursor.push()/pop() inside SwiftUI's .onHover because
/// cursor rects are managed at the window level and don't conflict with
/// SwiftUI's internal cursor handling.
private class PointerCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

private struct PointerCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return PointerCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Invalidate cursor rects when the view updates (e.g., resizes)
        // so AppKit recalculates the cursor area.
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

// MARK: - I-Beam Cursor (AppKit Bridge)

/// Uses AppKit's cursor rect system to reliably show an I-beam (text selection) cursor.
/// Same approach as PointerCursorView — cursor rects are managed at the window level
/// and don't conflict with SwiftUI's internal cursor handling.
/// Unlike NSCursor.push()/pop() in .onHover, this avoids cursor stack imbalance
/// when the mouse moves quickly between views.
private class IBeamCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    /// Pass through all mouse events so the TextField underneath still receives
    /// focus, clicks, and text selection. Cursor rects are registered with the
    /// window (via resetCursorRects) and work independently of hit testing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

struct IBeamCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return IBeamCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Invalidate cursor rects when the view updates (e.g., resizes)
        // so AppKit recalculates the cursor area.
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

// MARK: - Native Tooltip

/// Uses AppKit's `NSView.toolTip` to show a tooltip on hover.
/// SwiftUI's `.help()` conflicts with `.onHover` tracking areas, so
/// this bridges directly to AppKit's tooltip system which works independently.
private struct NativeTooltipView: NSViewRepresentable {
    let tooltip: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.toolTip = tooltip
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = tooltip
    }
}

extension View {
    /// Attaches a native macOS tooltip that works even alongside `.onHover`.
    func nativeTooltip(_ text: String?) -> some View {
        if let text = text, !text.isEmpty {
            return AnyView(self.overlay(NativeTooltipView(tooltip: text)))
        } else {
            return AnyView(self)
        }
    }
}

// MARK: - Color Utilities

extension Color {
    /// Create a Color from a hex string like "#FF5733" or "FF5733".
    init(hex: String) {
        let hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var rgbValue: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgbValue)

        let red = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let green = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let blue = Double(rgbValue & 0x0000FF) / 255.0

        self.init(red: red, green: green, blue: blue)
    }

    /// Returns a lighter version of this color by blending toward white.
    /// `fraction` is 0.0 (no change) to 1.0 (pure white).
    func blendedWithWhite(fraction: Double) -> Color {
        // Convert to NSColor to access RGB components for blending
        guard let nsColor = NSColor(self).usingColorSpace(.sRGB) else { return self }

        let red = nsColor.redComponent + (1.0 - nsColor.redComponent) * fraction
        let green = nsColor.greenComponent + (1.0 - nsColor.greenComponent) * fraction
        let blue = nsColor.blueComponent + (1.0 - nsColor.blueComponent) * fraction

        return Color(red: red, green: green, blue: blue)
    }
}
