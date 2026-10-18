//
//  OverlayWindow.swift
//  Cuse
//
//  System-wide transparent overlay window for blue glowing cursor.
//  One OverlayWindow is created per screen so the cursor buddy
//  seamlessly follows the cursor across multiple monitors.
//

import AppKit
import AVFoundation
import SwiftUI

class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        // Create window covering entire screen
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Make window transparent and non-interactive
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver  // Always on top, above submenus and popups
        self.ignoresMouseEvents = true  // Click-through
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false

        // Important: Allow the window to appear even when app is not active
        self.hidesOnDeactivate = false

        // Cover the entire screen
        self.setFrame(screen.frame, display: true)

        // Make sure it's on the right screen
        if let screenForWindow = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            self.setFrameOrigin(screenForWindow.frame.origin)
        }
    }

    // Prevent window from becoming key (no focus stealing)
    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }
}

// Lucide mouse-pointer-2 shape, ported into SwiftUI so the macOS app
// uses the same cursor silhouette as the web Cuse project.
struct CursorArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let viewBoxSize: CGFloat = 24
        let scale = min(rect.width, rect.height) / viewBoxSize
        let originX = rect.midX - (viewBoxSize * scale / 2)
        let originY = rect.midY - (viewBoxSize * scale / 2)

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: originX + x * scale,
                y: originY + y * scale
            )
        }

        // A narrow blade. The tip stays at the top-left of the 24pt box so the
        // existing rotation still aims it at the target.
        path.move(to: point(3.2, 3.2))
        path.addLine(to: point(16.4, 9.6))
        path.addLine(to: point(11.2, 11.2))
        path.addLine(to: point(9.6, 16.4))
        path.closeSubpath()
        return path
    }
}

// PreferenceKey for tracking bubble size
struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct NavigationBubbleSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private struct FocusHighlightTrailView: View {
    let screenFrame: CGRect
    let activeGlobalPoints: [CGPoint]
    let committedContext: FocusHighlightContext?

    var body: some View {
        TimelineView(.animation) { timeline in
            let points = currentTrailPoints
            CursorStreakTrailView(trailPoints: localTrailPoints(from: points))
                .opacity(trailOpacity(at: timeline.date, pointCount: points.count))
                .allowsHitTesting(false)
        }
    }

    private var currentTrailPoints: [CGPoint] {
        if !activeGlobalPoints.isEmpty {
            return activeGlobalPoints
        }
        return committedContext?.globalAppKitPoints ?? []
    }

    private func localTrailPoints(from globalPoints: [CGPoint]) -> [CGPoint] {
        globalPoints
            .suffix(220)
            .filter { screenFrame.insetBy(dx: -24, dy: -24).contains($0) }
            .map(localPoint)
    }

    private func trailOpacity(at date: Date, pointCount: Int) -> Double {
        guard pointCount >= 2 else { return 0 }
        guard activeGlobalPoints.isEmpty,
              let committedContext else {
            return 1
        }

        let secondsSinceCommit = date.timeIntervalSince(committedContext.createdAt)
        let holdSeconds: TimeInterval = 1.6
        let fadeSeconds: TimeInterval = 7.0
        guard secondsSinceCommit > holdSeconds else { return 1 }

        let fadeProgress = min(1, (secondsSinceCommit - holdSeconds) / fadeSeconds)
        return max(0, 1 - fadeProgress)
    }

    private func localPoint(from globalPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: globalPoint.x - screenFrame.minX,
            y: screenFrame.height - (globalPoint.y - screenFrame.minY)
        )
    }
}

/// The buddy's behavioral mode. Controls whether it follows the cursor,
/// is flying toward a detected UI element, or is pointing at an element.
enum BuddyNavigationMode {
    /// Default — buddy follows the mouse cursor with spring animation
    case followingCursor
    /// Buddy is animating toward a detected UI element location
    case navigatingToTarget
    /// Buddy has arrived at the target and is pointing at it with a speech bubble
    case pointingAtTarget
}

private enum PointerApproachSide {
    case leftOfTarget
    case rightOfTarget
    case aboveTarget
    case belowTarget
    case upperLeftOfTarget
    case upperRightOfTarget
    case lowerLeftOfTarget
    case lowerRightOfTarget

    var targetDirectionRadians: Double {
        switch self {
        case .leftOfTarget:
            return 0
        case .rightOfTarget:
            return .pi
        case .aboveTarget:
            return .pi / 2
        case .belowTarget:
            return -.pi / 2
        case .upperLeftOfTarget:
            return .pi / 4
        case .upperRightOfTarget:
            return .pi * 3.0 / 4.0
        case .lowerLeftOfTarget:
            return -.pi / 4.0
        case .lowerRightOfTarget:
            return -.pi * 3.0 / 4.0
        }
    }

    var prefersBubbleOnLeft: Bool {
        switch self {
        case .leftOfTarget, .upperLeftOfTarget, .lowerLeftOfTarget:
            return true
        case .rightOfTarget, .aboveTarget, .belowTarget, .upperRightOfTarget, .lowerRightOfTarget:
            return false
        }
    }

    var isCornerPose: Bool {
        switch self {
        case .upperLeftOfTarget, .upperRightOfTarget, .lowerLeftOfTarget, .lowerRightOfTarget:
            return true
        case .leftOfTarget, .rightOfTarget, .aboveTarget, .belowTarget:
            return false
        }
    }
}

private struct PointerLandingPose {
    let center: CGPoint
    let rotationDegrees: Double
    let side: PointerApproachSide
}

// SwiftUI view for the blue glowing cursor pointer.
// Each screen gets its own BlueCursorView. The view checks whether
// the cursor is currently on THIS screen and only shows the buddy
// triangle when it is. During voice interaction, the triangle is
// replaced by a waveform (listening), spinner (processing), or
// streaming text bubble (responding).
struct BlueCursorView: View {
    let screenFrame: CGRect
    let isFirstAppearance: Bool
    @ObservedObject var companionManager: CompanionManager

    @State private var cursorPosition: CGPoint
    @State private var rawCursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool

    /// Horizontal offset from `cursorPosition` to the LEFT edge of
    /// bubbles / labels that sit next to the cursor. Needs to clear
    /// the visible cursor glyph so the bubble doesn't get overdrawn.
    /// Triangle is 16pt wide (±8), cat is 32pt (±16) — so we push
    /// the bubble further right in Neko mode.
    private var bubbleLeftOffsetFromCursor: CGFloat {
        companionManager.isNekoModeEnabled ? 22 : 10
    }

    /// Vertical offset from `cursorPosition` to the TOP edge of
    /// bubbles. Same sizing logic as the horizontal offset.
    private var bubbleTopOffsetFromCursor: CGFloat {
        companionManager.isNekoModeEnabled ? 24 : 18
    }

    init(screenFrame: CGRect, isFirstAppearance: Bool, companionManager: CompanionManager) {
        self.screenFrame = screenFrame
        self.isFirstAppearance = isFirstAppearance
        self.companionManager = companionManager

        // Seed the cursor position from the current mouse location so the
        // buddy doesn't flash at (0,0) before onAppear fires.
        let mouseLocation = NSEvent.mouseLocation
        let localX = mouseLocation.x - screenFrame.origin.x
        let localY = screenFrame.height - (mouseLocation.y - screenFrame.origin.y)
        let rawInitialPosition = CGPoint(x: localX, y: localY)
        _rawCursorPosition = State(initialValue: rawInitialPosition)
        _cursorPosition = State(initialValue: CGPoint(x: localX + 35, y: localY + 25))
        _isCursorOnThisScreen = State(initialValue: screenFrame.contains(mouseLocation))
    }
    @State private var timer: Timer?
    @State private var welcomeText: String = ""
    @State private var showWelcome: Bool = true
    @State private var bubbleSize: CGSize = .zero
    @State private var bubbleOpacity: Double = 1.0
    @State private var cursorOpacity: Double = 0.0

    // MARK: - Buddy Navigation State

    /// The buddy's current behavioral mode (following cursor, navigating, or pointing).
    @State private var buddyNavigationMode: BuddyNavigationMode = .followingCursor

    /// The rotation angle of the arrow in degrees. The Lucide cursor
    /// shape already points up-left at 0°.
    /// Changes to face the direction of travel when navigating to a target.
    @State private var triangleRotationDegrees: Double = 0.0

    /// Speech bubble text shown when pointing at a detected element.
    @State private var navigationBubbleText: String = ""
    @State private var navigationBubbleOpacity: Double = 0.0
    @State private var navigationBubbleSize: CGSize = .zero
    @State private var navigationPointerApproachSide: PointerApproachSide = .rightOfTarget
    @State private var navigationPointingRotationDegrees: Double = 0.0
    @State private var isPointerBreathing: Bool = false

    /// The cursor position at the moment navigation started, used to detect
    /// if the user moves the cursor enough to cancel the navigation.
    @State private var cursorPositionWhenNavigationStarted: CGPoint = .zero

    /// Timer driving the frame-by-frame bezier arc flight animation.
    /// Invalidated when the flight completes, is canceled, or the view disappears.
    @State private var navigationAnimationTimer: Timer?

    /// Scale factor applied to the buddy triangle during flight. Grows to ~1.3x
    /// at the midpoint of the arc and shrinks back to 1.0x on landing, creating
    /// an energetic "swooping" feel.
    @State private var buddyFlightScale: CGFloat = 1.0

    /// Scale factor for the navigation speech bubble's pop-in entrance.
    /// Starts at 0.5 and springs to 1.0 when the first character appears.
    @State private var navigationBubbleScale: CGFloat = 1.0

    /// True when the buddy is flying BACK to the cursor after pointing.
    /// Only during the return flight can cursor movement cancel the animation.
    @State private var isReturningToCursor: Bool = false

    /// Rolling buffer of recent buddy positions during bezier flight, used to
    /// render the Olympic-fencing-style glowing trail behind the triangle.
    /// Oldest point is at index 0; newest (current head) is at the last index.
    @State private var flightTrailPoints: [CGPoint] = []

    /// Maximum number of points kept in the trail buffer. At 60fps this is
    /// roughly 0.35 seconds of history — long enough to feel like a trailing
    /// wisp, short enough to keep the effect subtle and hug the buddy closely.
    private let maximumFlightTrailPointCount: Int = 22

    /// Rolling movement trail shown behind the default arrow while the
    /// voice session is active and the user moves the mouse. This is
    /// separate from `flightTrailPoints`, which belongs to programmatic
    /// cursor flights toward resolved UI elements.
    @State private var followingTrailPoints: [CGPoint] = []

    private let maximumFollowingTrailPointCount: Int = 50
    @State private var followingTrailFramesWithoutMovement: Int = 0

    /// Opacity of the entire fencing trail overlay. Held at 1.0 during flight
    /// and animated to 0.0 over ~0.3s after landing for a smooth dissolve.
    @State private var flightTrailOpacity: Double = 0.0

    private let fullWelcomeMessage = "hey! i'm cuse"

    private let navigationPointerPhrases = [
        "right here!",
        "this one!",
        "over here!",
        "click this!",
        "here it is!",
        "found it!"
    ]

    var body: some View {
        ZStack {
            // Nearly transparent background (helps with compositing)
            Color.black.opacity(0.001)

            FocusHighlightTrailView(
                screenFrame: screenFrame,
                activeGlobalPoints: companionManager.isFocusHighlightActive
                    ? companionManager.focusHighlightGlobalPoints
                    : [],
                committedContext: companionManager.lastFocusHighlightContext
            )

            if companionManager.isRadialInputSwitcherVisible,
               let radialInputSwitcherCenter = companionManager.radialInputSwitcherCenter,
               screenFrame.contains(radialInputSwitcherCenter) {
                RadialInputSwitcherView(
                    highlightedOption: companionManager.highlightedRadialInputOption
                )
                .position(convertScreenPointToSwiftUICoordinates(radialInputSwitcherCenter))
                .zIndex(20)
            }

            if companionManager.isDetectionOverlayEnabled
                && (companionManager.detectionOverlayDisplayFrame == nil
                    || companionManager.detectionOverlayDisplayFrame == screenFrame) {
                DetectionOverlayView(
                    elements: companionManager.detectionOverlayElements,
                    highlightedLabel: companionManager.detectionOverlayHighlightedLabel,
                    screenFrame: screenFrame,
                    imageSize: companionManager.detectionOverlayImageSize,
                    cursorPoint: isCursorOnThisScreen ? rawCursorPosition : nil
                )
            }

            if !companionManager.isNekoModeEnabled
                && companionManager.globalPushToTalkShortcutMonitor.isShortcutCurrentlyPressed
                && buddyNavigationMode == .followingCursor {
                CursorStreakTrailView(trailPoints: followingTrailPoints)
                    .opacity(buddyIsVisibleOnThisScreen ? cursorOpacity : 0)
                    .allowsHitTesting(false)
            }

            // Welcome speech bubble (first launch only)
            if isCursorOnThisScreen && showWelcome && !welcomeText.isEmpty {
                Text(welcomeText)
                    .font(DS.Typography.medium(12))
                    .foregroundColor(DS.Colors.textPrimary)
                    .dsOverlayLabelChrome()
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(bubbleOpacity)
                    .position(
                        x: cursorPosition.x + bubbleLeftOffsetFromCursor + (bubbleSize.width / 2),
                        y: cursorPosition.y + bubbleTopOffsetFromCursor
                    )
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.5), value: bubbleOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            // Shortcut hint for the mode chosen during setup.
            if isCursorOnThisScreen && companionManager.showOnboardingPrompt && !companionManager.onboardingPromptText.isEmpty {
                Text(companionManager.onboardingPromptText)
                    .font(DS.Typography.medium(12))
                    .foregroundColor(DS.Colors.textPrimary)
                    .dsOverlayLabelChrome()
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(companionManager.onboardingPromptOpacity)
                    .position(
                        x: cursorPosition.x + bubbleLeftOffsetFromCursor + (bubbleSize.width / 2),
                        y: cursorPosition.y + bubbleTopOffsetFromCursor
                    )
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.4), value: companionManager.onboardingPromptOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            // Navigation pointer bubble — shown only after the buddy has
            // landed and softly settled near the target.
            if buddyNavigationMode == .pointingAtTarget && !navigationBubbleText.isEmpty {
                Text(navigationBubbleText)
                    .font(DS.Typography.medium(12))
                    .foregroundColor(DS.Colors.textPrimary)
                    .dsOverlayLabelChrome()
                    .shadow(
                        color: DS.Colors.overlayCursor.opacity(0.35 + (1.0 - navigationBubbleScale) * 0.4),
                        radius: 8,
                        x: 0, y: 4
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: NavigationBubbleSizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .scaleEffect(navigationBubbleScale)
                    .opacity(navigationBubbleOpacity)
                    .position(navigationBubblePosition())
                    .animation(.easeInOut(duration: 0.22), value: navigationBubbleScale)
                    .animation(.easeOut(duration: 0.28), value: navigationBubbleOpacity)
                    .onPreferenceChange(NavigationBubbleSizePreferenceKey.self) { newSize in
                        navigationBubbleSize = newSize
                    }
            }

            // Trail rendered BEHIND the buddy during a programmatic bezier
            // flight. Neko mode still leaves paw-print footprints behind
            // the running cat. The default-mode glow trail was removed —
            // during a flight to a UI element the buddy alone communicates
            // intent and the trailing line was noisy / distracting.
            if companionManager.isNekoModeEnabled {
                PawPrintTrailView(trailPoints: flightTrailPoints)
                    .opacity(flightTrailOpacity)
                    .allowsHitTesting(false)
            }

            // Default arrow cursor — shown when idle or while TTS is playing (responding).
            // All three states (arrow, waveform, spinner) stay in the view tree
            // permanently and cross-fade via opacity so SwiftUI doesn't remove/re-insert
            // them (which caused a visible cursor "pop").
            //
            // During cursor following: fast spring animation for snappy tracking.
            // Neko mode swaps the arrow for a pixel-art cat
            // that picks its own directional sprite from the cursor's
            // velocity and animates a 2-frame run cycle. Behavior is
            // unchanged — purely a visual personality toggle.
            if companionManager.isNekoModeEnabled {
                NekoCursorView(
                    position: cursorPosition,
                    opacity: buddyIsVisibleOnThisScreen ? cursorOpacity : 0,
                    flightScale: buddyFlightScale
                )
                .animation(
                    buddyNavigationMode == .followingCursor
                        ? .spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0)
                        : nil,
                    value: cursorPosition
                )
            } else {
                // During navigation: NO implicit position animation. The
                // time-based flight loop owns every point so SwiftUI does
                // not fight it with a second animation system.
                ZStack {
                    CursorArrowShape()
                        .fill(DS.Colors.overlayCursor)
                        .blur(radius: 16)
                        .opacity(0.32)
                    CursorArrowShape()
                        .fill(DS.Colors.overlayCursor)
                        .blur(radius: 6)
                        .opacity(0.38)
                    CursorArrowShape()
                        .fill(DS.Colors.overlayCursorFill)
                    CursorArrowShape()
                        .stroke(
                            DS.Colors.overlayCursor,
                            style: StrokeStyle(lineWidth: 4.2, lineCap: .round, lineJoin: .round)
                        )
                }
                    .frame(width: 44, height: 44)
                    .rotationEffect(.degrees(triangleRotationDegrees))
                    .opacity(buddyIsVisibleOnThisScreen ? cursorOpacity : 0)
                    .scaleEffect(
                        buddyNavigationMode == .pointingAtTarget && isPointerBreathing
                            ? 1.035
                            : buddyFlightScale
                    )
                    .position(cursorPosition)
                    .animation(
                        buddyNavigationMode == .followingCursor
                            ? .spring(response: 0.24, dampingFraction: 0.74, blendDuration: 0)
                            : nil,
                        value: cursorPosition
                    )
                    .animation(.easeIn(duration: 0.25), value: companionManager.voiceState)
                    .animation(
                        .easeInOut(duration: 1.4).repeatForever(autoreverses: true),
                        value: isPointerBreathing
                    )
                    .animation(nil, value: triangleRotationDegrees)
            }

            // Audio/transcript pill — floats next to the cursor and stays
            // visible through both listening and responding states, unless
            // a pointing label bubble is showing.
            let waveformIsVisible: Bool = {
                guard buddyIsVisibleOnThisScreen else { return false }
                if companionManager.detectedElementScreenLocation != nil {
                    return false
                }
                return companionManager.voiceState == .listening
                    || companionManager.voiceState == .responding
            }()

            // The pill's intrinsic width varies with transcript text length.
            // To keep its LEFT edge pinned at a constant offset to the right
            // of the cursor regardless of width, we content-size the pill
            // with `.fixedSize()` and place it inside a wider leading-aligned
            // outer frame. `.position` then anchors the outer frame, while
            // the pill remains flush against that frame's leading edge — so
            // its left edge sits a constant distance to the right of the
            // cursor no matter what the transcript says.
            let pillOuterFrameWidth: CGFloat = 240
            let pillLeftEdgeOffsetFromCursorCenter: CGFloat = 30
            let waveformPosition = CGPoint(
                x: cursorPosition.x + pillLeftEdgeOffsetFromCursorCenter + pillOuterFrameWidth / 2,
                y: cursorPosition.y
            )

            BlueCursorWaveformView(
                audioPowerLevel: companionManager.currentAudioPowerLevel,
                transcript: companionManager.lastTranscript
            )
                .fixedSize()
                .frame(width: pillOuterFrameWidth, height: 36, alignment: .leading)
                .opacity(waveformIsVisible ? cursorOpacity : 0)
                .position(waveformPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: waveformPosition)
                .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)

            // Blue spinner — shown while the AI is processing or JEV is choosing an action
            BlueCursorSpinnerView()
                .opacity(buddyIsVisibleOnThisScreen && companionManager.voiceState == .processing ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)

        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .onAppear {
            // Set initial cursor position immediately before starting animation
            let mouseLocation = NSEvent.mouseLocation
            isCursorOnThisScreen = screenFrame.contains(mouseLocation)

            let swiftUIPosition = convertScreenPointToSwiftUICoordinates(mouseLocation)
            self.rawCursorPosition = swiftUIPosition
            self.cursorPosition = CGPoint(x: swiftUIPosition.x + 35, y: swiftUIPosition.y + 25)

            startTrackingCursor()

            // Only show welcome message on first appearance (app start)
            // and only if the cursor starts on this screen
            if isFirstAppearance && isCursorOnThisScreen {
                withAnimation(.easeIn(duration: 2.0)) {
                    self.cursorOpacity = 1.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                    startWelcomeAnimation()
                }
            } else {
                self.cursorOpacity = 1.0
            }
        }
        .onDisappear {
            timer?.invalidate()
            navigationAnimationTimer?.invalidate()
        }
        .onChange(of: companionManager.detectedElementScreenLocation) { newLocation in
            // When a UI element location is detected, navigate the buddy to
            // that position so it points at the element.
            guard let screenLocation = newLocation,
                  let displayFrame = companionManager.detectedElementDisplayFrame else {
                return
            }

            // Only navigate if the target is on THIS screen
            guard screenFrame.contains(CGPoint(x: displayFrame.midX, y: displayFrame.midY))
                  || displayFrame == screenFrame else {
                return
            }

            startNavigatingToElement(screenLocation: screenLocation)
        }
    }

    /// Whether the buddy triangle should be visible on this screen.
    /// True when cursor is on this screen during normal following, or
    /// when navigating/pointing at a target on this screen. When another
    /// screen is navigating (detectedElementScreenLocation is set but this
    /// screen isn't the one animating), hide the cursor so only one buddy
    /// is ever visible at a time.
    private var buddyIsVisibleOnThisScreen: Bool {
        switch buddyNavigationMode {
        case .followingCursor:
            // If another screen's BlueCursorView is navigating to an element,
            // hide the cursor on this screen to prevent a duplicate buddy
            if companionManager.detectedElementScreenLocation != nil {
                return false
            }
            return isCursorOnThisScreen
        case .navigatingToTarget, .pointingAtTarget:
            return true
        }
    }

    // MARK: - Cursor Tracking

    private func startTrackingCursor() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            let mouseLocation = NSEvent.mouseLocation
            self.isCursorOnThisScreen = self.screenFrame.contains(mouseLocation)

            // During forward flight or pointing, the buddy is NOT interrupted by
            // mouse movement — it completes its full animation and return flight.
            // Only during the RETURN flight do we allow cursor movement to cancel
            // (so the buddy snaps to following if the user moves while it's flying back).
            if self.buddyNavigationMode == .navigatingToTarget && self.isReturningToCursor {
                let currentMouseInSwiftUI = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
                let distanceFromNavigationStart = hypot(
                    currentMouseInSwiftUI.x - self.cursorPositionWhenNavigationStarted.x,
                    currentMouseInSwiftUI.y - self.cursorPositionWhenNavigationStarted.y
                )
                if distanceFromNavigationStart > 100 {
                    cancelNavigationAndResumeFollowing()
                }
                return
            }

            // During forward navigation or pointing, just skip cursor tracking
            if self.buddyNavigationMode != .followingCursor {
                return
            }

            // Normal cursor following
            let swiftUIPosition = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
            self.rawCursorPosition = swiftUIPosition
            let buddyX = swiftUIPosition.x + 35
            let buddyY = swiftUIPosition.y + 25
            let nextCursorPosition = CGPoint(x: buddyX, y: buddyY)
            self.updateFollowingTrail(nextCursorPosition: nextCursorPosition)
            self.cursorPosition = nextCursorPosition
        }
    }

    private func updateFollowingTrail(nextCursorPosition: CGPoint) {
        guard !companionManager.isNekoModeEnabled,
              companionManager.globalPushToTalkShortcutMonitor.isShortcutCurrentlyPressed,
              isCursorOnThisScreen,
              buddyNavigationMode == .followingCursor else {
            followingTrailPoints.removeAll()
            followingTrailFramesWithoutMovement = 0
            return
        }

        let previousPoint = followingTrailPoints.last ?? cursorPosition

        let movementDistance = hypot(
            nextCursorPosition.x - previousPoint.x,
            nextCursorPosition.y - previousPoint.y
        )

        if movementDistance > 3.0 {
            followingTrailFramesWithoutMovement = 0

            // EMA-smooth the recorded position toward the raw sample. The
            // 60Hz cursor sampling timer runs on the main RunLoop, which
            // also services Gemini Live's audio chunk dispatches and JPEG
            // screenshot encoding during an active voice session. Those
            // bursts of main-thread work delay the timer just enough that
            // raw samples come in at uneven intervals, and Catmull-Rom
            // tangents amplify the irregular spacing into a visible
            // mid-curve wobble. Smoothing the inputs before they land in
            // the trail buffer hides that timing noise behind a small
            // amount of lag — fine for a trail that's meant to read as
            // "behind the cursor" anyway. The cursor sprite itself is
            // unaffected and stays locked to the real mouse position.
            let emaSmoothingCoefficient: CGFloat = 0.45
            let smoothedNextCursorPosition = CGPoint(
                x: previousPoint.x + (nextCursorPosition.x - previousPoint.x) * emaSmoothingCoefficient,
                y: previousPoint.y + (nextCursorPosition.y - previousPoint.y) * emaSmoothingCoefficient
            )

            followingTrailPoints.append(smoothedNextCursorPosition)
            if followingTrailPoints.count > maximumFollowingTrailPointCount {
                followingTrailPoints.removeFirst(
                    followingTrailPoints.count - maximumFollowingTrailPointCount
                )
            }
            return
        }

        followingTrailFramesWithoutMovement += 1
        if followingTrailFramesWithoutMovement > 5, !followingTrailPoints.isEmpty {
            followingTrailPoints.removeFirst()
        }
    }

    /// Converts a macOS screen point (AppKit, bottom-left origin) to SwiftUI
    /// coordinates (top-left origin) relative to this screen's overlay window.
    private func convertScreenPointToSwiftUICoordinates(_ screenPoint: CGPoint) -> CGPoint {
        let x = screenPoint.x - screenFrame.origin.x
        let y = (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        return CGPoint(x: x, y: y)
    }

    private func navigationBubblePosition() -> CGPoint {
        let horizontalOffset = bubbleLeftOffsetFromCursor + navigationBubbleSize.width / 2
        let verticalOffset = bubbleTopOffsetFromCursor

        if navigationPointerApproachSide.prefersBubbleOnLeft {
            return CGPoint(
                x: cursorPosition.x - horizontalOffset,
                y: cursorPosition.y + verticalOffset
            )
        }

        return CGPoint(
            x: cursorPosition.x + horizontalOffset,
            y: cursorPosition.y + verticalOffset
        )
    }

    // MARK: - Element Navigation

    /// Starts animating the buddy toward a detected UI element location.
    private func startNavigatingToElement(screenLocation: CGPoint) {
        // Don't interrupt welcome animation
        guard !showWelcome || welcomeText.isEmpty else { return }

        // Convert the AppKit screen location to SwiftUI coordinates for this screen
        let targetInSwiftUI = convertScreenPointToSwiftUICoordinates(screenLocation)
        let landingPose = pointerLandingPose(for: targetInSwiftUI)

        // Record the current cursor position so we can detect if the user
        // moves the mouse enough to cancel the return flight
        let mouseLocation = NSEvent.mouseLocation
        cursorPositionWhenNavigationStarted = convertScreenPointToSwiftUICoordinates(mouseLocation)

        // Enter navigation mode — stop cursor following
        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = false
        isPointerBreathing = false
        navigationPointerApproachSide = landingPose.side
        navigationPointingRotationDegrees = landingPose.rotationDegrees

        animateBezierFlightArc(to: landingPose.center, landingRotationDegrees: landingPose.rotationDegrees) {
            guard self.buddyNavigationMode == .navigatingToTarget else { return }
            self.startPointingAtElement()
        }
    }

    private func pointerLandingPose(for target: CGPoint) -> PointerLandingPose {
        let pointerDistanceFromTarget: CGFloat = 42
        let screenPadding: CGFloat = 34
        let candidateSides: [PointerApproachSide] = [
            .upperRightOfTarget,
            .upperLeftOfTarget,
            .lowerRightOfTarget,
            .lowerLeftOfTarget,
            .rightOfTarget,
            .leftOfTarget,
            .aboveTarget,
            .belowTarget
        ]

        func vector(for side: PointerApproachSide) -> CGVector {
            let radians = side.targetDirectionRadians
            return CGVector(dx: cos(radians), dy: sin(radians))
        }

        func clamped(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: max(screenPadding, min(point.x, screenFrame.width - screenPadding)),
                y: max(screenPadding, min(point.y, screenFrame.height - screenPadding))
            )
        }

        let bestCandidate = candidateSides
            .map { side -> (side: PointerApproachSide, center: CGPoint, score: CGFloat) in
                let targetDirection = vector(for: side)
                let idealCenter = CGPoint(
                    x: target.x - targetDirection.dx * pointerDistanceFromTarget,
                    y: target.y - targetDirection.dy * pointerDistanceFromTarget
                )
                let center = clamped(idealCenter)
                let clampPenalty = hypot(center.x - idealCenter.x, center.y - idealCenter.y) * 4.0
                let travelPenalty = hypot(center.x - cursorPosition.x, center.y - cursorPosition.y) * 0.08
                let horizontalBonus: CGFloat = {
                    switch side {
                    case .upperLeftOfTarget, .upperRightOfTarget, .lowerLeftOfTarget, .lowerRightOfTarget:
                        return 28
                    case .leftOfTarget, .rightOfTarget:
                        return 18
                    case .aboveTarget, .belowTarget:
                        return 0
                    }
                }()
                let cornerPenalty: CGFloat = side.isCornerPose ? 0 : 8
                let targetClearance = min(
                    target.x,
                    screenFrame.width - target.x,
                    target.y,
                    screenFrame.height - target.y
                ) * 0.02
                return (
                    side: side,
                    center: center,
                    score: horizontalBonus + targetClearance - clampPenalty - travelPenalty - cornerPenalty
                )
            }
            .max { lhs, rhs in lhs.score < rhs.score }

        let side = bestCandidate?.side ?? .upperRightOfTarget
        let fallbackOffset = pointerDistanceFromTarget / sqrt(2)
        let center = bestCandidate?.center ?? clamped(
            CGPoint(x: target.x + fallbackOffset, y: target.y - fallbackOffset)
        )
        let angleToTarget = atan2(target.y - center.y, target.x - center.x)

        return PointerLandingPose(
            center: center,
            rotationDegrees: cursorRotationDegrees(pointingAlongRadians: angleToTarget),
            side: side
        )
    }

    private func cursorRotationDegrees(pointingAlongRadians radians: Double) -> Double {
        // The Lucide cursor tip points roughly up-left at 0deg. Add this
        // offset so a world-space angle of 0deg makes the tip face right,
        // 180deg makes it face left, and vertical targets work too.
        radians * (180.0 / .pi) + 137.0
    }

    private func interpolatedAngleDegrees(from start: Double, to end: Double, amount: Double) -> Double {
        var delta = (end - start).truncatingRemainder(dividingBy: 360)
        if delta > 180 {
            delta -= 360
        } else if delta < -180 {
            delta += 360
        }
        return start + delta * amount
    }

    /// Animates the buddy along a restrained cubic bezier arc from its current
    /// position to the destination. The arrow follows the travel direction
    /// early, then eases into the landing pose before it reaches the target.
    private func animateBezierFlightArc(
        to destination: CGPoint,
        landingRotationDegrees: Double? = nil,
        followsTravelRotation: Bool = true,
        onComplete: @escaping () -> Void
    ) {
        navigationAnimationTimer?.invalidate()

        let startPosition = cursorPosition
        let endPosition = destination

        let deltaX = endPosition.x - startPosition.x
        let deltaY = endPosition.y - startPosition.y
        let distance = hypot(deltaX, deltaY)

        // Flight duration scales with distance: short hops are quick, long
        // flights are more dramatic. Clamped to 0.6s–1.4s for the triangle.
        // Neko mode runs longer — the cat sprite reads as "running" so a
        // leisurely pace feels more natural than an arrow's fast arc.
        let isNekoMode = companionManager.isNekoModeEnabled
        let flightDurationSeconds: Double = {
            if isNekoMode {
                return min(max(distance / 420.0, 1.5), 2.8)
            }
            return min(max(distance / 520.0, 1.05), 2.2)
        }()
        let frameInterval: TimeInterval = 1.0 / 60.0
        let startTime = CACurrentMediaTime()

        let unitDirection = CGVector(
            dx: distance > 0 ? deltaX / distance : 1,
            dy: distance > 0 ? deltaY / distance : 0
        )
        let normal = CGVector(dx: -unitDirection.dy, dy: unitDirection.dx)
        let arcDirection: CGFloat = startPosition.x <= endPosition.x ? -1 : 1
        let controlDistance = min(max(distance * 0.38, 70), 220)
        let arcHeight = min(max(distance * 0.08, 18), 58) * arcDirection
        let controlPoint1 = CGPoint(
            x: startPosition.x + unitDirection.dx * controlDistance + normal.dx * arcHeight,
            y: startPosition.y + unitDirection.dy * controlDistance + normal.dy * arcHeight
        )
        let controlPoint2 = CGPoint(
            x: endPosition.x - unitDirection.dx * controlDistance - normal.dx * arcHeight * 0.65,
            y: endPosition.y - unitDirection.dy * controlDistance - normal.dy * arcHeight * 0.65
        )
        var previousAnimatedPoint = startPosition
        var smoothedRotationDegrees = triangleRotationDegrees

        // Seed the fencing trail with the start position so the first rendered
        // frame has at least one segment to draw, and make the trail fully
        // opaque for the duration of this flight.
        flightTrailPoints = [startPosition]
        flightTrailOpacity = 1.0

        navigationAnimationTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { _ in
            let elapsedSeconds = CACurrentMediaTime() - startTime
            let linearProgress = min(1.0, elapsedSeconds / flightDurationSeconds)

            if linearProgress >= 1.0 {
                self.navigationAnimationTimer?.invalidate()
                self.navigationAnimationTimer = nil
                self.cursorPosition = endPosition
                self.buddyFlightScale = 1.0
                self.fadeOutFencingTrail()
                self.settleAtDestination(
                    destination: endPosition,
                    landingRotationDegrees: landingRotationDegrees,
                    onComplete: onComplete
                )
                return
            }

            // Smootherstep easeInOut. It lingers a touch at takeoff/landing,
            // which makes the buddy read more like a floating object than
            // a linearly animated pointer.
            let t = linearProgress * linearProgress * linearProgress
                * (linearProgress * (linearProgress * 6.0 - 15.0) + 10.0)

            // Cubic bezier flight path. Keep the curve soft and restrained:
            // the pointer should feel relaxed, not like it is darting.
            let oneMinusT = 1.0 - t
            let bezierX = oneMinusT * oneMinusT * oneMinusT * startPosition.x
                + 3.0 * oneMinusT * oneMinusT * t * controlPoint1.x
                + 3.0 * oneMinusT * t * t * controlPoint2.x
                + t * t * t * endPosition.x
            let bezierY = oneMinusT * oneMinusT * oneMinusT * startPosition.y
                + 3.0 * oneMinusT * oneMinusT * t * controlPoint1.y
                + 3.0 * oneMinusT * t * t * controlPoint2.y
                + t * t * t * endPosition.y

            let animatedPoint = CGPoint(x: bezierX, y: bezierY)
            self.cursorPosition = animatedPoint

            let travelAngle = atan2(
                animatedPoint.y - previousAnimatedPoint.y,
                animatedPoint.x - previousAnimatedPoint.x
            )
            let travelRotation = self.cursorRotationDegrees(pointingAlongRadians: travelAngle)
            let targetRotation: Double
            if followsTravelRotation, let landingRotationDegrees {
                let landingBlendStart = 0.66
                let rawLandingBlend = min(
                    1.0,
                    max(0.0, (linearProgress - landingBlendStart) / (1.0 - landingBlendStart))
                )
                let easedLandingBlend = rawLandingBlend * rawLandingBlend * (3.0 - 2.0 * rawLandingBlend)
                targetRotation = self.interpolatedAngleDegrees(
                    from: travelRotation,
                    to: landingRotationDegrees,
                    amount: easedLandingBlend
                )
            } else if followsTravelRotation {
                targetRotation = travelRotation
            } else {
                targetRotation = landingRotationDegrees ?? smoothedRotationDegrees
            }
            smoothedRotationDegrees = self.interpolatedAngleDegrees(
                from: smoothedRotationDegrees,
                to: targetRotation,
                amount: followsTravelRotation ? 0.11 : 0.05
            )
            self.triangleRotationDegrees = smoothedRotationDegrees
            previousAnimatedPoint = animatedPoint

            // Scale pulse: sin curve peaks at midpoint of the flight.
            // Buddy grows slightly at the apex, then shrinks back on landing.
            let scalePulse = sin(linearProgress * .pi)
            self.buddyFlightScale = 1.0 + scalePulse * 0.045

            // Append the new head to the fencing trail and drop the oldest
            // point if we're past the rolling-buffer cap. Keeping the trail
            // short guarantees the glow stays close to the buddy and fades
            // naturally behind it rather than persisting across the screen.
            self.flightTrailPoints.append(animatedPoint)
            if self.flightTrailPoints.count > self.maximumFlightTrailPointCount {
                self.flightTrailPoints.removeFirst(
                    self.flightTrailPoints.count - self.maximumFlightTrailPointCount
                )
            }
        }
    }

    private func settleAtDestination(
        destination: CGPoint,
        landingRotationDegrees: Double?,
        onComplete: @escaping () -> Void
    ) {
        let settleOffset = CGPoint(
            x: (cursorPosition.x - destination.x) * 0.08,
            y: (cursorPosition.y - destination.y) * 0.08
        )
        cursorPosition = CGPoint(
            x: destination.x + settleOffset.x,
            y: destination.y + settleOffset.y
        )

        withAnimation(.easeInOut(duration: 0.22)) {
            cursorPosition = destination
            buddyFlightScale = 1.0
            if let landingRotationDegrees {
                triangleRotationDegrees = landingRotationDegrees
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            guard self.buddyNavigationMode == .navigatingToTarget else { return }
            onComplete()
        }
    }

    /// Fades the fencing trail out over ~0.3s after a flight completes, then
    /// clears the buffer so the next flight starts from a clean slate.
    private func fadeOutFencingTrail() {
        withAnimation(.easeOut(duration: 0.45)) {
            flightTrailOpacity = 0.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.47) {
            // Only wipe the buffer if another flight hasn't already started
            // and re-set opacity to 1.0 in the interim.
            if self.flightTrailOpacity == 0.0 {
                self.flightTrailPoints.removeAll()
            }
        }
    }

    /// Transitions to pointing mode — shows a speech bubble with a bouncy
    /// scale-in entrance and variable-speed character streaming.
    private func startPointingAtElement() {
        buddyNavigationMode = .pointingAtTarget

        // Hold the landing pose so the cursor tip points into the resolved
        // target from whichever side had the most room.
        withAnimation(.easeInOut(duration: 0.28)) {
            triangleRotationDegrees = navigationPointingRotationDegrees
        }
        isPointerBreathing = true

        // Reset navigation bubble state. Keep the entrance understated so it
        // doesn't steal attention from the target.
        navigationBubbleText = ""
        navigationBubbleOpacity = 1.0
        navigationBubbleSize = .zero
        navigationBubbleScale = 0.96

        // Use custom bubble text from the companion manager (e.g. onboarding demo)
        // if available, otherwise fall back to a random pointer phrase
        let pointerPhrase = companionManager.detectedElementBubbleText
            ?? navigationPointerPhrases.randomElement()
            ?? "right here!"

        streamNavigationBubbleCharacter(phrase: pointerPhrase, characterIndex: 0) {
            // All characters streamed — hold for 3 seconds, then fly back
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                guard self.buddyNavigationMode == .pointingAtTarget else { return }
                self.navigationBubbleOpacity = 0.0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard self.buddyNavigationMode == .pointingAtTarget else { return }
                    self.startFlyingBackToCursor()
                }
            }
        }
    }

    /// Streams the navigation bubble text one character at a time with variable
    /// delays (30–60ms) for a natural "speaking" rhythm.
    private func streamNavigationBubbleCharacter(
        phrase: String,
        characterIndex: Int,
        onComplete: @escaping () -> Void
    ) {
        guard buddyNavigationMode == .pointingAtTarget else { return }
        guard characterIndex < phrase.count else {
            onComplete()
            return
        }

        let charIndex = phrase.index(phrase.startIndex, offsetBy: characterIndex)
        navigationBubbleText.append(phrase[charIndex])

        // On the first character, let the bubble ease into place.
        if characterIndex == 0 {
            navigationBubbleScale = 1.0
        }

        let characterDelay = Double.random(in: 0.03...0.06)
        DispatchQueue.main.asyncAfter(deadline: .now() + characterDelay) {
            self.streamNavigationBubbleCharacter(
                phrase: phrase,
                characterIndex: characterIndex + 1,
                onComplete: onComplete
            )
        }
    }

    /// Flies the buddy back to the current cursor position after pointing is done.
    private func startFlyingBackToCursor() {
        let mouseLocation = NSEvent.mouseLocation
        let cursorInSwiftUI = convertScreenPointToSwiftUICoordinates(mouseLocation)
        let cursorWithTrackingOffset = CGPoint(x: cursorInSwiftUI.x + 35, y: cursorInSwiftUI.y + 25)
        let returnDistance = hypot(
            cursorWithTrackingOffset.x - cursorPosition.x,
            cursorWithTrackingOffset.y - cursorPosition.y
        )

        cursorPositionWhenNavigationStarted = cursorInSwiftUI

        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = true
        isPointerBreathing = false

        if returnDistance < 72 {
            navigationAnimationTimer?.invalidate()
            navigationAnimationTimer = nil
            fadeOutFencingTrail()
            dockBackToCursor(destination: cursorWithTrackingOffset)
            return
        }

        animateBezierFlightArc(
            to: cursorWithTrackingOffset,
            landingRotationDegrees: 0,
            followsTravelRotation: false
        ) {
            self.finishNavigationAndResumeFollowing()
        }
    }

    private func dockBackToCursor(destination: CGPoint) {
        let startPosition = cursorPosition
        let startRotation = triangleRotationDegrees
        let durationSeconds: TimeInterval = 0.34
        let frameInterval: TimeInterval = 1.0 / 60.0
        let startTime = CACurrentMediaTime()

        navigationAnimationTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { _ in
            let elapsedSeconds = CACurrentMediaTime() - startTime
            let linearProgress = min(1.0, elapsedSeconds / durationSeconds)
            let t = linearProgress * linearProgress * (3.0 - 2.0 * linearProgress)

            self.cursorPosition = CGPoint(
                x: startPosition.x + (destination.x - startPosition.x) * t,
                y: startPosition.y + (destination.y - startPosition.y) * t
            )
            self.triangleRotationDegrees = self.interpolatedAngleDegrees(
                from: startRotation,
                to: 0,
                amount: t
            )
            self.buddyFlightScale = 1.0

            if linearProgress >= 1.0 {
                self.navigationAnimationTimer?.invalidate()
                self.navigationAnimationTimer = nil
                self.cursorPosition = destination
                self.triangleRotationDegrees = 0
                guard self.buddyNavigationMode == .navigatingToTarget else { return }
                self.finishNavigationAndResumeFollowing()
            }
        }
    }

    /// Cancels an in-progress navigation because the user moved the cursor.
    private func cancelNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        buddyFlightScale = 1.0
        isPointerBreathing = false
        fadeOutFencingTrail()
        finishNavigationAndResumeFollowing()
    }

    /// Returns the buddy to normal cursor-following mode after navigation completes.
    private func finishNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        buddyNavigationMode = .followingCursor
        isReturningToCursor = false
        isPointerBreathing = false
        triangleRotationDegrees = 0.0
        buddyFlightScale = 1.0
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        companionManager.clearDetectedElementLocation()
    }

    // MARK: - Welcome Animation

    private func startWelcomeAnimation() {
        withAnimation(.easeIn(duration: 0.4)) {
            self.bubbleOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < self.fullWelcomeMessage.count else {
                timer.invalidate()
                // Hold the text for 2 seconds, then fade it out
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    self.showWelcome = false
                    // Continue straight
                    // from the welcome bubble to the "press ctrl+opt"
                    // prompt so the user sees the cat cursor and can
                    // start talking immediately.
                    self.companionManager.showOnboardingHotkeyPrompt()
                }
                return
            }

            let index = self.fullWelcomeMessage.index(self.fullWelcomeMessage.startIndex, offsetBy: currentIndex)
            self.welcomeText.append(self.fullWelcomeMessage[index])
            currentIndex += 1
        }
    }
}

// MARK: - Fencing Trail

/// Olympic-fencing-broadcast-style glowing trail rendered behind the buddy
/// during a programmatic bezier flight toward a resolved UI element.
/// Same single-continuous-path + layered-blur recipe as the highlighter
/// trail, but tuned thinner and quieter so it reads as a wispy comet tail
/// behind the buddy instead of a chunky marker stroke.
struct FencingTrailView: View {
    let trailPoints: [CGPoint]

    var body: some View {
        ZStack {
            buildUniformFlightTrailLayer(
                lineWidth: 22.0,
                strokeOpacity: 0.07,
                postBlurRadius: 16
            )

            buildUniformFlightTrailLayer(
                lineWidth: 12.0,
                strokeOpacity: 0.16,
                postBlurRadius: 6
            )

            buildUniformFlightTrailLayer(
                lineWidth: 5.5,
                strokeOpacity: 0.34,
                postBlurRadius: 0
            )
        }
    }

    /// One stroke pass over the entire smoothed flight-trail path at a
    /// constant width and constant opacity, followed by a uniform blur for
    /// the layer's glow halo. Single-stroke-per-layer prevents the bead
    /// artifacts that a per-segment approach produces at junctions.
    private func buildUniformFlightTrailLayer(
        lineWidth: CGFloat,
        strokeOpacity: Double,
        postBlurRadius: CGFloat
    ) -> some View {
        Canvas { graphicsContext, _ in
            guard trailPoints.count > 1 else { return }

            let continuousSmoothFlightTrailPath = buildContinuousSmoothTrailPath(
                trailPoints: trailPoints
            )

            graphicsContext.stroke(
                continuousSmoothFlightTrailPath,
                with: .color(DS.Colors.overlayCursor.opacity(strokeOpacity)),
                style: StrokeStyle(
                    lineWidth: lineWidth,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }
        .blur(radius: postBlurRadius)
    }
}

/// Builds one continuous smooth path that flows through every point in
/// `trailPoints` using centripetal Catmull-Rom-derived cubic Bezier
/// segments. Each consecutive pair of points becomes a cubic curve whose
/// control points are taken from the two neighboring points, which gives
/// C1 continuity across the whole trail.
///
/// Drawing the trail as ONE continuous path that we stroke a single time
/// per layer is what removes the visible "beads" along the curve. The
/// previous implementation stroked every segment as its own path with
/// `lineCap: .round`, and adjacent caps with slightly different widths
/// stacked into visible dots — building one path and stroking it once
/// eliminates that artifact entirely.
///
/// For the first segment we reuse `trailPoints[0]` itself as the missing
/// previous neighbor; for the last segment we reuse `trailPoints.last`
/// for the missing next neighbor. That keeps the curve passing exactly
/// through both endpoints.
private func buildContinuousSmoothTrailPath(trailPoints: [CGPoint]) -> Path {
    var continuousTrailPath = Path()
    guard trailPoints.count > 1 else { return continuousTrailPath }

    if trailPoints.count == 2 {
        continuousTrailPath.move(to: trailPoints[0])
        continuousTrailPath.addLine(to: trailPoints[1])
        return continuousTrailPath
    }

    continuousTrailPath.move(to: trailPoints[0])
    let lastTrailPointIndex = trailPoints.count - 1

    for segmentIndex in 0..<lastTrailPointIndex {
        let segmentStartPoint = trailPoints[segmentIndex]
        let segmentEndPoint = trailPoints[segmentIndex + 1]

        let pointBeforeSegmentStart = segmentIndex == 0
            ? trailPoints[0]
            : trailPoints[segmentIndex - 1]
        let pointAfterSegmentEnd = (segmentIndex + 2) <= lastTrailPointIndex
            ? trailPoints[segmentIndex + 2]
            : trailPoints[lastTrailPointIndex]

        let tangentAtSegmentStart = CGPoint(
            x: (segmentEndPoint.x - pointBeforeSegmentStart.x) / 2.0,
            y: (segmentEndPoint.y - pointBeforeSegmentStart.y) / 2.0
        )
        let tangentAtSegmentEnd = CGPoint(
            x: (pointAfterSegmentEnd.x - segmentStartPoint.x) / 2.0,
            y: (pointAfterSegmentEnd.y - segmentStartPoint.y) / 2.0
        )

        let firstCubicControlPoint = CGPoint(
            x: segmentStartPoint.x + tangentAtSegmentStart.x / 3.0,
            y: segmentStartPoint.y + tangentAtSegmentStart.y / 3.0
        )
        let secondCubicControlPoint = CGPoint(
            x: segmentEndPoint.x - tangentAtSegmentEnd.x / 3.0,
            y: segmentEndPoint.y - tangentAtSegmentEnd.y / 3.0
        )

        continuousTrailPath.addCurve(
            to: segmentEndPoint,
            control1: firstCubicControlPoint,
            control2: secondCubicControlPoint
        )
    }

    return continuousTrailPath
}

/// Thick blue highlighter-style trail rendered behind the cursor while a
/// voice session is active. Looks like a fat blue marker stroke with a
/// soft glow around it, fading smoothly into the background at the tail.
///
/// Each visual layer (halo / bloom / core) is drawn by stroking many short
/// `trimmedPath` slices of the same continuous Catmull-Rom-smoothed path,
/// where each slice gets its own opacity along a tail→head ramp. Using
/// butt caps means the slices abut without overlap, so the opacity
/// transitions stay clean — no beads at junctions, no width-mismatch
/// artifacts. Quadratic easing concentrates the fade near the tail so
/// most of the trail stays saturated and only the last segment softly
/// dissolves, matching the highlighter aesthetic of the reference.
struct CursorStreakTrailView: View {
    let trailPoints: [CGPoint]

    var body: some View {
        ZStack {
            buildSoftFadingTrailLayer(
                lineWidth: 54.0,
                maxStrokeOpacity: 0.11,
                postBlurRadius: 30
            )

            buildSoftFadingTrailLayer(
                lineWidth: 32.0,
                maxStrokeOpacity: 0.26,
                postBlurRadius: 12
            )

            buildSoftFadingTrailLayer(
                lineWidth: 18.0,
                maxStrokeOpacity: 0.72,
                postBlurRadius: 0
            )
        }
    }

    /// Number of butt-capped slices used to approximate a smooth opacity
    /// gradient along the trail. Higher values give a smoother fade but
    /// more strokes per frame; 28 is enough that the opacity steps blur
    /// out invisibly after the layer's Gaussian blur is applied.
    private let opacityFadeBandCount: Int = 28

    /// Strokes the trail as a stack of constant-width slices along the
    /// smoothed path. Slice opacity ramps from 0 at the tail to
    /// `maxStrokeOpacity` at the head, on a quadratic curve so the fade
    /// is concentrated at the very tail and the rest of the trail stays
    /// fully saturated — that's what produces the highlighter look
    /// where the marker dissolves softly into nothing.
    private func buildSoftFadingTrailLayer(
        lineWidth: CGFloat,
        maxStrokeOpacity: Double,
        postBlurRadius: CGFloat
    ) -> some View {
        Canvas { graphicsContext, _ in
            guard trailPoints.count > 1 else { return }

            let continuousSmoothTrailPath = buildContinuousSmoothTrailPath(
                trailPoints: trailPoints
            )

            for bandIndex in 0..<opacityFadeBandCount {
                let bandStartFraction = Double(bandIndex) / Double(opacityFadeBandCount)
                let bandEndFraction = Double(bandIndex + 1) / Double(opacityFadeBandCount)
                let bandCenterFraction = (bandStartFraction + bandEndFraction) / 2.0

                // 0.0 at the tail (oldest sample), 1.0 at the head
                // (newest, right behind the cursor). The 1.8 exponent
                // pushes most of the fade into the last ~30% of the
                // trail length so the marker dissolves only at its end.
                let fadeAlongTrail = pow(bandCenterFraction, 1.8)
                let bandStrokeOpacity = maxStrokeOpacity * fadeAlongTrail

                let bandPath = continuousSmoothTrailPath.trimmedPath(
                    from: bandStartFraction,
                    to: bandEndFraction
                )

                graphicsContext.stroke(
                    bandPath,
                    with: .color(DS.Colors.overlayCursor.opacity(bandStrokeOpacity)),
                    style: StrokeStyle(
                        lineWidth: lineWidth,
                        lineCap: .butt,
                        lineJoin: .round
                    )
                )
            }
        }
        .blur(radius: postBlurRadius)
    }
}

// MARK: - Blue Cursor Waveform

/// Light-blue speech pill that shows a compact audio animation plus
/// Gemini Live's incremental user transcript.
private struct BlueCursorWaveformView: View {
    let audioPowerLevel: CGFloat
    let transcript: String?

    private var displayTranscript: String {
        let trimmedTranscript = (transcript ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")

        guard !trimmedTranscript.isEmpty else {
            return "Listening"
        }

        let maximumCharacterCount = 34
        if trimmedTranscript.count <= maximumCharacterCount {
            return trimmedTranscript
        }
        return String(trimmedTranscript.suffix(maximumCharacterCount))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            MiniAudioGlyph(audioPowerLevel: audioPowerLevel)

            Text(displayTranscript)
                .font(DS.Typography.medium(13))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(minWidth: 70, maxWidth: 180, alignment: .leading)
        }
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .frame(height: 34)
        .background(
            Capsule(style: .continuous)
                .fill(DS.Colors.background.opacity(0.97))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 4)
        .animation(.linear(duration: 0.08), value: audioPowerLevel)
    }
}

private struct MiniAudioGlyph: View {
    let audioPowerLevel: CGFloat

    private let barProfile: [CGFloat] = [0.45, 1.0, 0.78]
    @State private var isPulsing = false

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<3, id: \.self) { barIndex in
                Capsule(style: .continuous)
                    .fill(DS.Colors.overlayCursor.opacity(barIndex == 0 ? 0.42 : 1.0))
                    .frame(
                        width: 3,
                        height: barHeight(for: barIndex)
                    )
            }
        }
        .frame(width: 18, height: 18)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.48).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }

    private func barHeight(for barIndex: Int) -> CGFloat {
        let normalizedAudioPowerLevel = max(audioPowerLevel - 0.008, 0)
        let easedAudioPowerLevel = pow(min(normalizedAudioPowerLevel * 2.85, 1), 0.76)
        let reactiveHeight = easedAudioPowerLevel * 11 * barProfile[barIndex]
        let idlePulse = isPulsing
            ? CGFloat([1.0, 0.15, 0.65][barIndex]) * 1.8
            : CGFloat([0.15, 1.0, 0.35][barIndex]) * 1.8
        return 3 + reactiveHeight + idlePulse
    }
}

// MARK: - Blue Cursor Spinner

/// A small blue spinning indicator that replaces the triangle cursor
/// while the AI is processing a voice input.
private struct BlueCursorSpinnerView: View {
    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(
                AngularGradient(
                    colors: [
                        DS.Colors.overlayCursor.opacity(0.0),
                        DS.Colors.overlayCursor
                    ],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .shadow(color: DS.Colors.overlayCursor.opacity(0.6), radius: 6, x: 0, y: 0)
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    isSpinning = true
                }
            }
    }
}

// Manager for overlay windows — creates one per screen so the cursor
// buddy seamlessly follows the cursor across multiple monitors.
@MainActor
class OverlayWindowManager {
    private var overlayWindows: [OverlayWindow] = []
    var hasShownOverlayBefore = false

    func showOverlay(onScreens screens: [NSScreen], companionManager: CompanionManager) {
        // Hide any existing overlays
        hideOverlay()

        // Track if this is the first time showing overlay (welcome message)
        let isFirstAppearance = !hasShownOverlayBefore
        hasShownOverlayBefore = true

        // Create one overlay window per screen
        for screen in screens {
            let window = OverlayWindow(screen: screen)

            let contentView = BlueCursorView(
                screenFrame: screen.frame,
                isFirstAppearance: isFirstAppearance,
                companionManager: companionManager
            )

            let hostingView = NSHostingView(rootView: contentView)
            hostingView.frame = screen.frame
            window.contentView = hostingView

            overlayWindows.append(window)
            window.orderFrontRegardless()
        }
    }

    func hideOverlay() {
        for window in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindows.removeAll()
    }

    /// Fades out overlay windows over `duration` seconds, then removes them.
    func fadeOutAndHideOverlay(duration: TimeInterval = 0.4) {
        let windowsToFade = overlayWindows
        overlayWindows.removeAll()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for window in windowsToFade {
                window.animator().alphaValue = 0
            }
        }, completionHandler: {
            for window in windowsToFade {
                window.orderOut(nil)
                window.contentView = nil
            }
        })
    }

    func isShowingOverlay() -> Bool {
        return !overlayWindows.isEmpty
    }
}
