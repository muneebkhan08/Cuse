//
//  ElementResolver.swift
//  Cuse
//
//  Single entry point for "where on screen should the cursor fly to?"
//
//  Tries lookup strategies in order of reliability:
//    1. macOS Accessibility tree (~30ms, pixel-perfect when the app
//       supports AX — almost all native Mac apps, most Cocoa third-party
//       apps, and Electron apps that respect AXManualAccessibility).
//    2. Browser DOM coordinates through CUA/CDP for Chromium web pages.
//    3. Local perception cache from the on-device overlay, which can
//       resolve visible labels without Gemini screenshot streaming.
//    4. Native detector cache refinement for apps with weak AX trees.
//    5. Raw Gemini-emitted box_2d coordinates as the absolute fallback.
//       These come from the same model that named the element, so they
//       reflect Gemini's spatial intent for that exact tool call.
//
//  The resolver returns a global AppKit screen coordinate so the cursor
//  overlay can fly to it without further conversion.
//

import AppKit
import Foundation

final class ElementResolver: @unchecked Sendable {

    static let shared = ElementResolver()

    private let axResolver = AccessibilityTreeResolver()
    private let browserCoordinateResolver = BrowserCoordinateResolver()

    // MARK: - Public Types

    /// Where the resolved coordinate came from — useful for logging and
    /// telling the cursor what confidence to render with.
    enum ResolutionSource {
        case accessibilityTree       // AX tree gave us exact frame
        case browserDOMCoordinates   // Browser DOM rect through CUA/CDP
        case nativeDetectorCache     // Local CoreML/Vision detector refined the model hint
        case localPerceptionCache    // Local overlay detector resolved without Gemini screenshot coords
        case llmRawCoordinates       // Straight from Gemini's box_2d, no refinement
    }

    struct Resolution {
        /// Global AppKit-space coordinate — ready to pass to the overlay.
        let globalScreenPoint: CGPoint
        /// The display the point is on.
        let displayFrame: CGRect
        /// Human-readable label describing what was pointed at.
        let label: String
        /// Where the resolution came from — for logging/telemetry.
        let source: ResolutionSource
        /// Global AppKit-space rect for the matched element, when the
        /// resolution source can produce one. AX always gives us this
        /// (pixel-perfect). Raw box_2d does not — the click detector
        /// falls back to a radius around `globalScreenPoint` when this
        /// is nil.
        let globalScreenRect: CGRect?
    }

    // MARK: - Resolution

    /// Try AX tree only. Runs on a background task so the walk doesn't
    /// block main. Returns nil if AX has no match for the label.
    /// `targetAppHint` (e.g. "Blender") lets us query the app the user
    /// is actually looking at when the system's focused app is a
    /// background recorder like Cap.
    func tryAccessibilityTree(label: String, targetAppHint: String? = nil) async -> Resolution? {
        let axResolverRef = axResolver
        let axResult = await Task.detached(priority: .userInitiated) {
            return axResolverRef.findElement(byLabel: label, targetAppHint: targetAppHint)
        }.value

        guard let axResult else { return nil }

        let globalPoint = await MainActor.run {
            displayFrameContaining(axResult.center) ?? axResult.screenFrame
        }
        print("[ElementResolver] ✓ AX matched \"\(label)\" → \"\(axResult.title)\" [\(axResult.role)] at \(axResult.center)")
        return Resolution(
            globalScreenPoint: axResult.center,
            displayFrame: globalPoint,
            label: label,
            source: .accessibilityTree,
            globalScreenRect: axResult.screenFrame
        )
    }

    func exactLocalTargetResolution(
        targetID: String?,
        targetMark: Int?,
        fallbackLabel: String
    ) -> Resolution? {
        let targets = LocalPerceptionTargetCache.shared.currentTargets()
        let matchedTarget: LocalPerceptionTargetCache.SnapshotTarget?
        if let targetID = targetID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !targetID.isEmpty {
            matchedTarget = targets.first(where: { $0.id == targetID })
        } else if let targetMark {
            matchedTarget = targets.first(where: { $0.mark == targetMark })
        } else {
            matchedTarget = nil
        }

        guard let matchedTarget,
              matchedTarget.globalCenter.count >= 2,
              matchedTarget.globalBox.count >= 4,
              matchedTarget.displayFrame.count >= 4 else {
            return nil
        }

        let globalScreenRect = Self.rect(from: matchedTarget.globalBox)
        let displayFrame = Self.rect(from: matchedTarget.displayFrame)
        let label = matchedTarget.label.isEmpty ? fallbackLabel : matchedTarget.label
        print("[ElementResolver] ✓ exact local target #\(matchedTarget.mark) \"\(label)\" [\(matchedTarget.source)] at \(matchedTarget.globalCenter)")
        return Resolution(
            globalScreenPoint: CGPoint(
                x: matchedTarget.globalCenter[0],
                y: matchedTarget.globalCenter[1]
            ),
            displayFrame: displayFrame,
            label: label,
            source: .localPerceptionCache,
            globalScreenRect: globalScreenRect
        )
    }

    /// Absolute last resort — use Gemini's raw box_2d coordinate as-is.
    func rawLLMCoordinate(
        label: String,
        llmHintInScreenshotPixels: CGPoint,
        capture: CompanionScreenCapture
    ) -> Resolution {
        let globalPoint = screenshotPixelToGlobalScreen(llmHintInScreenshotPixels, capture: capture)
        print("[ElementResolver] ⚠ using raw LLM coords for \"\(label)\" → screenshotPixel=\(llmHintInScreenshotPixels), capture=\(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels), displayFrame=\(capture.displayFrame), screen=\(globalPoint)")
        return Resolution(
            globalScreenPoint: globalPoint,
            displayFrame: capture.displayFrame,
            label: label,
            source: .llmRawCoordinates,
            globalScreenRect: nil
        )
    }

    /// Poll the AX tree repeatedly for up to `timeoutSeconds` waiting
    /// for `label` to appear. Returns the first successful resolution.
    /// Used by the workflow runner to wait for a newly-opened menu or
    /// sheet to settle after a click, instead of sleeping a fixed time.
    /// Polling is cheap (~20-40ms per tick) and exits early on match.
    func pollAccessibilityTree(
        label: String,
        targetAppHint: String?,
        timeoutSeconds: Double,
        pollIntervalSeconds: Double = 0.08
    ) async -> Resolution? {
        // Short-circuit for apps we already know don't expose an AX
        // tree (Blender, Unity, games). Saves up to a full `timeoutSeconds`
        // of wasted polling per step AND the CPU churn that causes
        // audio underruns in the Gemini Live output stream.
        if AccessibilityTreeResolver.isAppKnownToLackAXTree(hint: targetAppHint) {
            print("[AX] skipping poll for \"\(label)\" — app \"\(targetAppHint ?? "?")\" flagged as no-AX-tree")
            return nil
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let hit = await tryAccessibilityTree(label: label, targetAppHint: targetAppHint) {
                return hit
            }
            try? await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000))
        }
        return nil
    }

    /// Full resolution pipeline: AX → browser DOM/CDP → native detector → box_2d, tried in order
    /// with early exit.
    ///
    /// Tier order is deliberate:
    ///   1. AX tree first. Pixel-perfect when the app exposes one, and
    ///      it's the only path that gives us a real element rect for
    ///      the click detector to use as a tight hit region.
    ///   2. Browser DOM/CDP coordinates for Chromium pages.
    ///   3. Native detector cache for canvas/no-AX apps like Blender.
    ///      The model's box_2d becomes a proximity hint, then local
    ///      CoreML/OCR detections snap it to a real nearby UI box.
    ///   4. Gemini's box_2d as final fallback. Those coordinates are
    ///      the same model's spatial output for the same query — they
    ///      reflect everything Gemini knew at tool-call time.
    ///
    /// If every tier misses, we return nil — the caller surfaces this
    /// to the user rather than silently flying the cursor somewhere
    /// wrong.
    func resolve(
        label: String,
        llmHintInScreenshotPixels: CGPoint?,
        latestCapture: CompanionScreenCapture?,
        targetAppHint: String? = nil,
        proximityAnchorInGlobalScreen: CGPoint? = nil,
        preferLocalHintBeforeAccessibility: Bool = false
    ) async -> Resolution? {

        // Staleness check on the screenshot — resolving against a frame
        // >1s old means the cursor is likely to land on an element that
        // has moved or disappeared. Log so it shows up in traces; don't
        // block, because even a stale frame often works.
        if let capture = latestCapture {
            let ageSeconds = Date().timeIntervalSince(capture.captureTimestamp)
            if ageSeconds > 1.0 {
                print("[ElementResolver] ⚠ screenshot is \(String(format: "%.2f", ageSeconds))s old — coords may have drifted for \"\(label)\"")
            }
        }

        let shouldSkipAXAndBrowser = shouldSkipAXAndBrowserForVisionOnlyApp(targetAppHint: targetAppHint)
        if shouldSkipAXAndBrowser {
            print("[ElementResolver] ⏭ vision-only app \"\(targetAppHint ?? "?")\" — skipping AX/CDP for \"\(label)\"")
        }

        if preferLocalHintBeforeAccessibility,
           let localPerceptionResolution = localPerceptionResolution(
               label: label,
               llmHintInScreenshotPixels: llmHintInScreenshotPixels,
               proximityAnchorInGlobalScreen: proximityAnchorInGlobalScreen
           ) {
            return localPerceptionResolution
        }

        // 1. AX tree first — fastest and most reliable for native apps.
        //    Target app hint lets us bypass the system's "frontmost" when
        //    that's a background recorder (Cap) instead of the app the
        //    user is actually working in (e.g. Blender).
        //
        //    Skip the walk entirely when we've already learned this app
        //    has no AX tree (Blender/games/canvas apps). Saves 30-300ms
        //    of wasted IPC on every subsequent pointing call and — more
        //    importantly — the CPU that walk would burn while Gemini's
        //    audio is streaming.
        if !shouldSkipAXAndBrowser,
           !AccessibilityTreeResolver.isAppKnownToLackAXTree(hint: targetAppHint) {
            if let axResolution = await tryAccessibilityTree(label: label, targetAppHint: targetAppHint) {
                return axResolution
            }

        }

        // 2. Browser DOM/CDP coordinates. Chrome and other Chromium
        //    pages can expose better geometry through the page itself
        //    than through the macOS AX tree, especially for template
        //    cards and heavily styled web controls.
        if !shouldSkipAXAndBrowser {
            if let browserResolution = await browserCoordinateResolver.resolve(
                label: label,
                targetAppHint: targetAppHint
            ) {
                let displayFrame = await MainActor.run {
                    displayFrameContaining(browserResolution.globalScreenPoint)
                        ?? NSScreen.main?.frame
                        ?? .zero
                }
                return Resolution(
                    globalScreenPoint: browserResolution.globalScreenPoint,
                    displayFrame: displayFrame,
                    label: browserResolution.matchedLabel,
                    source: .browserDOMCoordinates,
                    globalScreenRect: browserResolution.globalScreenRect
                )
            }
        }

        // 3. Local perception cache from the on-device YOLO/OCR overlay.
        //    This path does not require Gemini screenshot streaming or
        //    a box_2d hint. It lets commands like "click Add" resolve
        //    entirely from local UI labels in canvas-heavy apps.
        if let localPerceptionResolution = localPerceptionResolution(
            label: label,
            llmHintInScreenshotPixels: llmHintInScreenshotPixels,
            proximityAnchorInGlobalScreen: proximityAnchorInGlobalScreen
        ) {
            return localPerceptionResolution
        }

        guard let capture = latestCapture else {
            print("[ElementResolver] ✗ no AX/local match and no screenshot capture — giving up on \"\(label)\"")
            return nil
        }

        // 4. If the native detector overlay/cache is warm, use it to
        //    refine the model's rough point before falling back raw.
        //    This matters for apps like Blender where AX exposes almost
        //    nothing, but the local detector can still see tabs/buttons.
        if let nativeDetectorResolution = await nativeDetectorResolution(
            label: label,
            llmHintInScreenshotPixels: llmHintInScreenshotPixels,
            capture: capture
        ) {
            return nativeDetectorResolution
        }

        // 5. Trust the model's box_2d when it gave us one. This is
        //    Gemini's spatial output for the same query that emitted
        //    the label — one model, one decision.
        if let hint = llmHintInScreenshotPixels {
            return rawLLMCoordinate(
                label: label,
                llmHintInScreenshotPixels: hint,
                capture: capture
            )
        }

        print("[ElementResolver] ✗ could not resolve \"\(label)\" — AX missed and no box_2d hint")
        return nil
    }

    private func localPerceptionResolution(
        label: String,
        llmHintInScreenshotPixels: CGPoint?,
        proximityAnchorInGlobalScreen: CGPoint?
    ) -> Resolution? {
        let cursorAnchor = proximityAnchorInGlobalScreen ?? NSEvent.mouseLocation
        guard let target = LocalPerceptionTargetCache.shared.resolve(
            label: label,
            preferMatchesNearGlobalPoint: cursorAnchor,
            pointHintInScreenshotPixels: llmHintInScreenshotPixels
        ) else {
            return nil
        }

        print("[ElementResolver] ✓ local perception resolved \"\(label)\" → \"\(target.label)\" [\(target.source)] at \(target.globalScreenPoint), cacheAge=\(target.cacheAgeMs)ms")
        return Resolution(
            globalScreenPoint: target.globalScreenPoint,
            displayFrame: target.displayFrame,
            label: target.label,
            source: .localPerceptionCache,
            globalScreenRect: target.globalScreenRect
        )
    }

    private static func rect(from array: [Double]) -> CGRect {
        CGRect(
            x: array[0],
            y: array[1],
            width: max(0, array[2] - array[0]),
            height: max(0, array[3] - array[1])
        )
    }

    private func nativeDetectorResolution(
        label: String,
        llmHintInScreenshotPixels: CGPoint?,
        capture: CompanionScreenCapture
    ) async -> Resolution? {
        var nativeDetectorMatch = nativeDetectorCachedMatch(
            label: label,
            llmHintInScreenshotPixels: llmHintInScreenshotPixels
        )

        if nativeDetectorMatch == nil,
           let screenshotImage = NSBitmapImageRep(data: capture.imageData)?.cgImage {
            _ = await NativeElementDetector.shared.detectElements(in: screenshotImage)
            nativeDetectorMatch = nativeDetectorCachedMatch(
                label: label,
                llmHintInScreenshotPixels: llmHintInScreenshotPixels
            )
        }

        guard let nativeDetectorMatch else { return nil }

        let globalPoint = screenshotPixelToGlobalScreen(nativeDetectorMatch.center, capture: capture)
        let globalRect = screenshotPixelRectToGlobalScreen(nativeDetectorMatch.bbox, capture: capture)
        print("[ElementResolver] ✓ native detector refined \"\(label)\" → \"\(nativeDetectorMatch.label)\" at screenshotPixel=\(nativeDetectorMatch.center), screen=\(globalPoint), cacheAge=\(nativeDetectorMatch.cacheAgeMs)ms")

        return Resolution(
            globalScreenPoint: globalPoint,
            displayFrame: capture.displayFrame,
            label: label,
            source: .nativeDetectorCache,
            globalScreenRect: globalRect
        )
    }

    private func nativeDetectorCachedMatch(
        label: String,
        llmHintInScreenshotPixels: CGPoint?
    ) -> NativeElementDetector.FoundElement? {
        if let hint = llmHintInScreenshotPixels {
            return NativeElementDetector.shared.refineCoordinate(hint: hint, label: label)
                ?? NativeElementDetector.shared.findFromCache(query: label, preferMatchesNearPixel: hint)
        }
        return NativeElementDetector.shared.findFromCache(query: label)
    }

    private func shouldSkipAXAndBrowserForVisionOnlyApp(targetAppHint: String?) -> Bool {
        guard let normalizedTargetAppHint = targetAppHint?.lowercased() else { return false }
        return normalizedTargetAppHint.contains("blender")
            || normalizedTargetAppHint.contains("org.blenderfoundation.blender")
    }

    // MARK: - Coordinate Conversion

    /// Convert a point in screenshot pixel space (top-left origin) to
    /// global AppKit screen coordinates (bottom-left origin, spans all displays).
    /// Uses the capture's metadata (display frame, pixel dimensions) to scale.
    private func screenshotPixelToGlobalScreen(_ pixel: CGPoint, capture: CompanionScreenCapture) -> CGPoint {
        let screenshotWidth = CGFloat(capture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(capture.screenshotHeightInPixels)
        let displayWidth = CGFloat(capture.displayWidthInPoints)
        let displayHeight = CGFloat(capture.displayHeightInPoints)
        let displayFrame = capture.displayFrame

        let clampedX = max(0, min(pixel.x, screenshotWidth))
        let clampedY = max(0, min(pixel.y, screenshotHeight))

        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (displayHeight / screenshotHeight)
        let appKitY = displayHeight - displayLocalY

        return CGPoint(
            x: displayLocalX + displayFrame.origin.x,
            y: appKitY + displayFrame.origin.y
        )
    }

    private func screenshotPixelRectToGlobalScreen(_ pixelRect: CGRect, capture: CompanionScreenCapture) -> CGRect {
        let topLeft = screenshotPixelToGlobalScreen(
            CGPoint(x: pixelRect.minX, y: pixelRect.minY),
            capture: capture
        )
        let bottomRight = screenshotPixelToGlobalScreen(
            CGPoint(x: pixelRect.maxX, y: pixelRect.maxY),
            capture: capture
        )

        return CGRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(topLeft.y - bottomRight.y)
        )
    }

    /// Find the NSScreen whose frame contains the given global AppKit point.
    private func displayFrameContaining(_ globalPoint: CGPoint) -> CGRect? {
        for screen in NSScreen.screens {
            if screen.frame.contains(globalPoint) {
                return screen.frame
            }
        }
        return nil
    }
}
