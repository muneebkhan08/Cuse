import SwiftUI

/// Draws native detector bounding boxes on the overlay.
/// Neon green boxes are CoreML UI detections; cyan boxes are Apple Vision OCR text.
struct DetectionOverlayView: View {
    let elements: [[String: Any]]
    let highlightedLabel: String?
    let screenFrame: CGRect
    let imageSize: [Int]  // [width, height] of the screenshot sent to YOLO
    let cursorPoint: CGPoint?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let animationPhase = timeline.date.timeIntervalSinceReferenceDate
                let pulse = (sin(animationPhase * 2.2) + 1.0) / 2.0
                let imgW = CGFloat(imageSize.count >= 2 ? imageSize[0] : 1512)
                let imgH = CGFloat(imageSize.count >= 2 ? imageSize[1] : 982)
                let scaleX = screenFrame.width / imgW
                let scaleY = screenFrame.height / imgH
                let overlayCandidates = elementCandidates(scaleX: scaleX, scaleY: scaleY)
                let labelEnrichedCandidates = candidatesWithResolvedLabels(overlayCandidates)
                let bubbleTarget = bubbleTarget(cursorPoint: cursorPoint, candidates: labelEnrichedCandidates)

                if let cursorPoint, let bubbleTarget {
                    drawBubbleCursor(
                        in: &context,
                        cursorPoint: cursorPoint,
                        target: bubbleTarget,
                        candidates: labelEnrichedCandidates,
                        pulse: pulse
                    )
                }

                for element in elements {
                    guard let bbox = element["bbox"] as? [Int], bbox.count == 4 else { continue }
                    let label = element["label"] as? String ?? ""
                    let conf = element["conf"] as? Double ?? 0
                    let source = element["source"] as? String ?? "yolo"
                    let isTextElement = source == "ocr"

                    let x1 = CGFloat(bbox[0]) * scaleX
                    let y1 = CGFloat(bbox[1]) * scaleY
                    let x2 = CGFloat(bbox[2]) * scaleX
                    let y2 = CGFloat(bbox[3]) * scaleY

                    let rect = CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
                    guard rect.width > 2, rect.height > 2 else { continue }

                    let isHighlighted = highlightedLabel != nil && label.lowercased().contains(highlightedLabel!.lowercased())
                    let controlBoxColor = DS.Colors.accent
                    let textBoxColor = DS.Colors.secondaryMark
                    let highlightBoxColor = DS.Colors.accent
                    let defaultBoxColor: Color = isTextElement ? textBoxColor : controlBoxColor
                    let boxColor: Color = isHighlighted ? highlightBoxColor : defaultBoxColor
                    let strokeOpacity: Double = isHighlighted ? 0.9 : (isTextElement ? 0.45 : 0.58)
                    let baseLineWidth: CGFloat = isHighlighted ? 2.0 : (isTextElement ? 0.75 : 0.9)
                    let glowOpacity = (isHighlighted ? 0.18 : 0.055) + pulse * 0.045

                    let roundedRectPath = Path(roundedRect: rect, cornerRadius: isTextElement ? 4 : 6)

                    context.stroke(
                        roundedRectPath,
                        with: .color(boxColor.opacity(glowOpacity)),
                        lineWidth: baseLineWidth + 3.8
                    )
                    context.stroke(
                        roundedRectPath,
                        with: .color(boxColor.opacity(glowOpacity + 0.06)),
                        lineWidth: baseLineWidth + 1.6
                    )

                    context.fill(
                        roundedRectPath,
                        with: .color(boxColor.opacity(isHighlighted ? 0.08 : 0.018))
                    )

                    context.stroke(
                        roundedRectPath,
                        with: .color(boxColor.opacity(strokeOpacity)),
                        lineWidth: baseLineWidth
                    )

                    drawCornerBrackets(in: &context, rect: rect, color: boxColor, opacity: strokeOpacity, lineWidth: baseLineWidth + 0.25)

                    if isHighlighted || (!label.isEmpty && rect.width >= 42 && rect.height >= 12) {
                        let displayText = label.isEmpty ? "" : label
                        guard !displayText.isEmpty || isHighlighted else { continue }
                        let fontSize: CGFloat = isHighlighted ? 9.5 : 7.5
                        let textColor: Color = DS.Colors.textPrimary
                        let textWidth = min(CGFloat(displayText.count) * fontSize * 0.58 + 14, max(58, screenFrame.width - x1 - 8))
                        let textSize = CGSize(width: textWidth, height: fontSize + 7)
                        let textRect = CGRect(
                            x: min(x1, max(0, screenFrame.width - textSize.width - 6)),
                            y: max(2, y1 - textSize.height - 4),
                            width: textSize.width,
                            height: textSize.height
                        )

                        context.fill(
                            Path(roundedRect: textRect, cornerRadius: 0),
                            with: .color(DS.Colors.background.opacity(isHighlighted ? 0.94 : 0.88))
                        )
                        context.stroke(
                            Path(roundedRect: textRect, cornerRadius: 5),
                            with: .color(boxColor.opacity(isHighlighted ? 0.76 : 0.28)),
                            lineWidth: 0.55
                        )

                        context.fill(
                            Path(
                                roundedRect: CGRect(x: textRect.minX, y: textRect.minY, width: 4, height: textRect.height),
                                cornerRadius: 2
                            ),
                            with: .color(boxColor.opacity(isHighlighted ? 0.85 : 0.55))
                        )

                        context.draw(
                            Text(displayText)
                                .font(DS.Typography.medium(fontSize))
                                .foregroundColor(textColor),
                            at: CGPoint(x: textRect.midX + 3, y: textRect.midY)
                        )
                    }

                    if conf > 0.5 && !isHighlighted {
                        let dotSize: CGFloat = isTextElement ? 2.2 : 3.0
                        context.fill(
                            Path(ellipseIn: CGRect(x: x2 - dotSize - 2, y: y1 + 2, width: dotSize, height: dotSize)),
                            with: .color(boxColor.opacity(0.86))
                        )
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.3), value: elements.count)
    }

    private func drawCornerBrackets(
        in context: inout GraphicsContext,
        rect: CGRect,
        color: Color,
        opacity: Double,
        lineWidth: CGFloat
    ) {
        let bracketLength = min(max(min(rect.width, rect.height) * 0.28, 8), 18)
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY + bracketLength))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + bracketLength, y: rect.minY))

        path.move(to: CGPoint(x: rect.maxX - bracketLength, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + bracketLength))

        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - bracketLength))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - bracketLength, y: rect.maxY))

        path.move(to: CGPoint(x: rect.minX + bracketLength, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bracketLength))

        context.stroke(path, with: .color(color.opacity(opacity)), lineWidth: lineWidth)
    }

    private struct OverlayCandidate {
        let rect: CGRect
        let label: String
        let source: String
        let confidence: Double
        let edgeDistance: CGFloat
        let centerDistance: CGFloat

        var center: CGPoint {
            CGPoint(x: rect.midX, y: rect.midY)
        }
    }

    private func elementCandidates(scaleX: CGFloat, scaleY: CGFloat) -> [OverlayCandidate] {
        elements.compactMap { element in
            guard let bbox = element["bbox"] as? [Int], bbox.count == 4 else { return nil }

            let source = element["source"] as? String ?? "yolo"
            let label = element["label"] as? String ?? ""
            let confidence = element["conf"] as? Double ?? 0
            let x1 = CGFloat(bbox[0]) * scaleX
            let y1 = CGFloat(bbox[1]) * scaleY
            let x2 = CGFloat(bbox[2]) * scaleX
            let y2 = CGFloat(bbox[3]) * scaleY
            let rect = CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)

            guard rect.width > 4, rect.height > 4 else { return nil }

            // OCR returns lots of small word boxes. Keep them visible as boxes,
            // but only let reasonably-sized OCR blocks participate in the bubble
            // target map so the cursor does not flicker between individual letters.
            if source == "ocr", rect.width < 36 || rect.height < 10 {
                return nil
            }

            return OverlayCandidate(
                rect: rect,
                label: label,
                source: source,
                confidence: confidence,
                edgeDistance: .infinity,
                centerDistance: .infinity
            )
        }
    }

    private func bubbleTarget(cursorPoint: CGPoint?, candidates: [OverlayCandidate]) -> OverlayCandidate? {
        guard let cursorPoint else { return nil }

        return candidates
            .map { candidate in
                OverlayCandidate(
                    rect: candidate.rect,
                    label: candidate.label,
                    source: candidate.source,
                    confidence: candidate.confidence,
                    edgeDistance: distance(from: cursorPoint, to: candidate.rect),
                    centerDistance: hypot(cursorPoint.x - candidate.center.x, cursorPoint.y - candidate.center.y)
                )
            }
            .min { firstCandidate, secondCandidate in
                let firstScore = firstCandidate.edgeDistance + firstCandidate.centerDistance * 0.02
                let secondScore = secondCandidate.edgeDistance + secondCandidate.centerDistance * 0.02
                return firstScore < secondScore
            }
    }

    private func candidatesWithResolvedLabels(_ candidates: [OverlayCandidate]) -> [OverlayCandidate] {
        let ocrCandidates = candidates.filter { $0.source == "ocr" && !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        return candidates.map { candidate in
            guard candidate.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return candidate
            }

            guard let resolvedLabel = bestOCRLabel(for: candidate, ocrCandidates: ocrCandidates) else {
                return candidate
            }

            return OverlayCandidate(
                rect: candidate.rect,
                label: resolvedLabel,
                source: candidate.source,
                confidence: candidate.confidence,
                edgeDistance: candidate.edgeDistance,
                centerDistance: candidate.centerDistance
            )
        }
    }

    private func bestOCRLabel(for candidate: OverlayCandidate, ocrCandidates: [OverlayCandidate]) -> String? {
        let expandedCandidateRect = candidate.rect.insetBy(dx: -10, dy: -8)
        let matchingOCRCandidates = ocrCandidates.compactMap { ocrCandidate -> (candidate: OverlayCandidate, score: CGFloat)? in
            let intersection = expandedCandidateRect.intersection(ocrCandidate.rect)
            let intersectionArea = max(0, intersection.width) * max(0, intersection.height)
            let ocrArea = max(1, ocrCandidate.rect.width * ocrCandidate.rect.height)
            let overlapRatio = intersectionArea / ocrArea
            let centerDistance = hypot(candidate.center.x - ocrCandidate.center.x, candidate.center.y - ocrCandidate.center.y)

            guard overlapRatio > 0.25 || centerDistance < max(candidate.rect.width, candidate.rect.height) * 0.9 else {
                return nil
            }

            let containmentBonus: CGFloat = candidate.rect.contains(ocrCandidate.center) ? 1000 : 0
            let overlapScore = overlapRatio * 800
            let distancePenalty = centerDistance * 0.8
            return (ocrCandidate, containmentBonus + overlapScore - distancePenalty)
        }
        .sorted { $0.score > $1.score }

        guard let bestOCRCandidate = matchingOCRCandidates.first?.candidate else {
            return nil
        }

        let nearbyOCRCandidates = matchingOCRCandidates
            .prefix(3)
            .map(\.candidate)
            .filter { abs($0.rect.midY - bestOCRCandidate.rect.midY) < max(14, bestOCRCandidate.rect.height * 0.8) }
            .sorted { $0.rect.minX < $1.rect.minX }

        let joinedLabel = nearbyOCRCandidates
            .map(\.label)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return joinedLabel.isEmpty ? nil : joinedLabel
    }

    private func drawBubbleCursor(
        in context: inout GraphicsContext,
        cursorPoint: CGPoint,
        target: OverlayCandidate,
        candidates: [OverlayCandidate],
        pulse: Double
    ) {
        let targetMarkColor = DS.Colors.accent
        let sortedCandidates = candidates
            .map { candidate in
                OverlayCandidate(
                    rect: candidate.rect,
                    label: candidate.label,
                    source: candidate.source,
                    confidence: candidate.confidence,
                    edgeDistance: distance(from: cursorPoint, to: candidate.rect),
                    centerDistance: hypot(cursorPoint.x - candidate.center.x, cursorPoint.y - candidate.center.y)
                )
            }
            .sorted { firstCandidate, secondCandidate in
                let firstScore = firstCandidate.edgeDistance + firstCandidate.centerDistance * 0.02
                let secondScore = secondCandidate.edgeDistance + secondCandidate.centerDistance * 0.02
                return firstScore < secondScore
            }

        let competitorDistance = sortedCandidates.dropFirst().first?.edgeDistance ?? 260
        let selectedDistance = max(0, target.edgeDistance)
        let bubbleRadius = min(max(min(selectedDistance + 20, competitorDistance - 8), 28), 260)
        let bubbleRect = CGRect(
            x: cursorPoint.x - bubbleRadius,
            y: cursorPoint.y - bubbleRadius,
            width: bubbleRadius * 2,
            height: bubbleRadius * 2
        )

        drawFlashlightCone(
            in: &context,
            cursorPoint: cursorPoint,
            targetRect: target.rect,
            color: targetMarkColor,
            pulse: pulse
        )

        context.fill(
            Path(ellipseIn: bubbleRect),
            with: .color(targetMarkColor.opacity(0.045 + pulse * 0.025))
        )
        context.stroke(
            Path(ellipseIn: bubbleRect),
            with: .color(targetMarkColor.opacity(0.16 + pulse * 0.10)),
            lineWidth: 10
        )
        context.stroke(
            Path(ellipseIn: bubbleRect),
            with: .color(targetMarkColor.opacity(0.86)),
            style: StrokeStyle(lineWidth: 1.4, dash: [7, 7])
        )

        let targetGlowRect = target.rect.insetBy(dx: -6, dy: -6)
        context.fill(
            Path(roundedRect: targetGlowRect, cornerRadius: 8),
            with: .color(targetMarkColor.opacity(0.12))
        )
        context.stroke(
            Path(roundedRect: targetGlowRect, cornerRadius: 8),
            with: .color(targetMarkColor.opacity(0.96)),
            lineWidth: 2.0
        )

        var rayPath = Path()
        rayPath.move(to: cursorPoint)
        rayPath.addLine(to: target.center)
        context.stroke(
            rayPath,
            with: .color(targetMarkColor.opacity(0.72)),
            style: StrokeStyle(lineWidth: 1.2, lineCap: .round)
        )

        let displayLabel = target.label.isEmpty ? target.source.uppercased() : target.label
        let labelText = Text(displayLabel)
            .font(DS.Typography.medium(11))
            .foregroundColor(DS.Colors.textPrimary)
        let labelWidth = min(max(CGFloat(displayLabel.count) * 6.4 + 18, 48), 190)
        let labelRect = CGRect(
            x: min(target.rect.maxX + 8, max(6, screenFrame.width - labelWidth - 8)),
            y: max(6, target.rect.minY - 24),
            width: labelWidth,
            height: 20
        )

        context.fill(
            Path(roundedRect: labelRect, cornerRadius: 0),
            with: .color(DS.Colors.background.opacity(0.92))
        )
        context.stroke(
            Path(roundedRect: labelRect, cornerRadius: 6),
            with: .color(targetMarkColor.opacity(0.72)),
            lineWidth: 0.8
        )
        context.draw(labelText, at: CGPoint(x: labelRect.midX, y: labelRect.midY))
    }

    private func drawFlashlightCone(
        in context: inout GraphicsContext,
        cursorPoint: CGPoint,
        targetRect: CGRect,
        color: Color,
        pulse: Double
    ) {
        let corners = [
            CGPoint(x: targetRect.minX, y: targetRect.minY),
            CGPoint(x: targetRect.maxX, y: targetRect.minY),
            CGPoint(x: targetRect.maxX, y: targetRect.maxY),
            CGPoint(x: targetRect.minX, y: targetRect.maxY)
        ]

        var widestPair = (corners[0], corners[1])
        var widestAngle: CGFloat = -.infinity

        for firstIndex in corners.indices {
            for secondIndex in corners.indices where secondIndex > firstIndex {
                let firstAngle = atan2(corners[firstIndex].y - cursorPoint.y, corners[firstIndex].x - cursorPoint.x)
                let secondAngle = atan2(corners[secondIndex].y - cursorPoint.y, corners[secondIndex].x - cursorPoint.x)
                let angleDifference = abs(atan2(sin(firstAngle - secondAngle), cos(firstAngle - secondAngle)))

                if angleDifference > widestAngle {
                    widestAngle = angleDifference
                    widestPair = (corners[firstIndex], corners[secondIndex])
                }
            }
        }

        var conePath = Path()
        conePath.move(to: cursorPoint)
        conePath.addLine(to: widestPair.0)
        conePath.addLine(to: widestPair.1)
        conePath.closeSubpath()

        context.fill(conePath, with: .color(color.opacity(0.13 + pulse * 0.05)))
        context.stroke(conePath, with: .color(color.opacity(0.34)), lineWidth: 1.0)
    }

    private func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let leftDistance = rect.minX - point.x
        let rightDistance = point.x - rect.maxX
        let topDistance = rect.minY - point.y
        let bottomDistance = point.y - rect.maxY
        let horizontalDistance = max(leftDistance, 0, rightDistance)
        let verticalDistance = max(topDistance, 0, bottomDistance)
        let outsideDistance = hypot(horizontalDistance, verticalDistance)

        if outsideDistance > 0 {
            return outsideDistance
        }

        let insideInset = min(
            point.x - rect.minX,
            rect.maxX - point.x,
            point.y - rect.minY,
            rect.maxY - point.y
        )
        return -insideInset
    }
}
