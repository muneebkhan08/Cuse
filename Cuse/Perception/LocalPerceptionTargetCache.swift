import AppKit
import Foundation

/// Stores the latest on-device UI perception pass in a form the action resolver
/// can use without asking Gemini for screenshot coordinates.
final class LocalPerceptionTargetCache: @unchecked Sendable {
    static let shared = LocalPerceptionTargetCache()

    struct SnapshotTarget: Encodable {
        let id: String
        let mark: Int
        let label: String
        let source: String
        let confidence: Double
        let screenshotBox: [Double]
        let normalizedBox2D: [Int]
        let globalCenter: [Double]
        let globalBox: [Double]
        let displayFrame: [Double]
        let cacheAgeMs: Int
    }

    struct ResolvedTarget {
        let label: String
        let source: String
        let globalScreenPoint: CGPoint
        let globalScreenRect: CGRect
        let displayFrame: CGRect
        let cacheAgeMs: Int
        let normalizedBox2D: [Int]
    }

    private struct Candidate {
        let screenshotRect: CGRect
        let label: String
        let source: String
        let confidence: Double

        var screenshotCenter: CGPoint {
            CGPoint(x: screenshotRect.midX, y: screenshotRect.midY)
        }
    }

    private struct CacheSnapshot {
        let candidates: [Candidate]
        let imageSize: CGSize
        let displayFrame: CGRect
        let timestamp: Date
    }

    private let lock = NSLock()
    private var snapshot: CacheSnapshot?

    private static let stopWords: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those",
        "button", "icon", "menu", "bar", "tab", "panel", "item", "option",
        "link", "field", "input", "box", "area", "section", "row", "cell",
        "click", "press", "open", "choose", "select"
    ]

    private init() {}

    func update(
        elements: [[String: Any]],
        imageSize: CGSize,
        displayFrame: CGRect
    ) {
        let parsedCandidates = parseCandidates(from: elements)
        let labelEnrichedCandidates = candidatesWithResolvedLabels(parsedCandidates)

        lock.lock()
        snapshot = CacheSnapshot(
            candidates: labelEnrichedCandidates,
            imageSize: imageSize,
            displayFrame: displayFrame,
            timestamp: Date()
        )
        lock.unlock()
    }

    func clear() {
        lock.lock()
        snapshot = nil
        lock.unlock()
    }

    func resolve(
        label: String,
        preferMatchesNearGlobalPoint: CGPoint? = nil,
        pointHintInScreenshotPixels: CGPoint? = nil
    ) -> ResolvedTarget? {
        lock.lock()
        let currentSnapshot = snapshot
        lock.unlock()

        guard let currentSnapshot else { return nil }

        let cacheAgeMs = Int(Date().timeIntervalSince(currentSnapshot.timestamp) * 1000)
        guard cacheAgeMs < 60_000 else { return nil }

        let proximityAnchorInScreenshotPixels = preferMatchesNearGlobalPoint.map {
            globalScreenPointToScreenshotPixel(
                $0,
                imageSize: currentSnapshot.imageSize,
                displayFrame: currentSnapshot.displayFrame
            )
        }

        guard let matchedCandidate = bestCandidate(
            matching: label,
            candidates: currentSnapshot.candidates,
            proximityAnchorInScreenshotPixels: proximityAnchorInScreenshotPixels
        ) else {
            return nil
        }

        let globalRect = screenshotPixelRectToGlobalScreen(
            matchedCandidate.screenshotRect,
            imageSize: currentSnapshot.imageSize,
            displayFrame: currentSnapshot.displayFrame
        )

        return ResolvedTarget(
            label: matchedCandidate.label.isEmpty ? label : matchedCandidate.label,
            source: matchedCandidate.source,
            globalScreenPoint: CGPoint(x: globalRect.midX, y: globalRect.midY),
            globalScreenRect: globalRect,
            displayFrame: currentSnapshot.displayFrame,
            cacheAgeMs: cacheAgeMs,
            normalizedBox2D: normalizedBox2D(
                for: matchedCandidate.screenshotRect,
                imageSize: currentSnapshot.imageSize
            )
        )
    }

    func currentTargets(limit: Int = 160) -> [SnapshotTarget] {
        lock.lock()
        let currentSnapshot = snapshot
        lock.unlock()

        guard let currentSnapshot else { return [] }

        let cacheAgeMs = Int(Date().timeIntervalSince(currentSnapshot.timestamp) * 1000)
        guard cacheAgeMs < 60_000 else { return [] }

        return currentSnapshot.candidates
            .filter { !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { first, second in
                let firstPriority = sourcePriority(first.source)
                let secondPriority = sourcePriority(second.source)
                if firstPriority == secondPriority {
                    return first.confidence > second.confidence
                }
                return firstPriority > secondPriority
            }
            .prefix(limit)
            .enumerated()
            .map { index, candidate in
                let globalRect = screenshotPixelRectToGlobalScreen(
                    candidate.screenshotRect,
                    imageSize: currentSnapshot.imageSize,
                    displayFrame: currentSnapshot.displayFrame
                )
                return SnapshotTarget(
                    id: targetID(for: candidate),
                    mark: index + 1,
                    label: candidate.label,
                    source: candidate.source,
                    confidence: candidate.confidence,
                    screenshotBox: Self.array(from: candidate.screenshotRect),
                    normalizedBox2D: normalizedBox2D(
                        for: candidate.screenshotRect,
                        imageSize: currentSnapshot.imageSize
                    ),
                    globalCenter: [globalRect.midX, globalRect.midY],
                    globalBox: Self.array(from: globalRect),
                    displayFrame: Self.array(from: currentSnapshot.displayFrame),
                    cacheAgeMs: cacheAgeMs
                )
            }
    }

    func freshTargetCount() -> Int {
        currentTargets().count
    }

    private func parseCandidates(from elements: [[String: Any]]) -> [Candidate] {
        elements.compactMap { element in
            guard let bbox = element["bbox"] as? [Int], bbox.count == 4 else { return nil }

            let minX = CGFloat(bbox[0])
            let minY = CGFloat(bbox[1])
            let maxX = CGFloat(bbox[2])
            let maxY = CGFloat(bbox[3])
            let rect = CGRect(
                x: min(minX, maxX),
                y: min(minY, maxY),
                width: abs(maxX - minX),
                height: abs(maxY - minY)
            )

            guard rect.width > 4, rect.height > 4 else { return nil }

            return Candidate(
                screenshotRect: rect,
                label: element["label"] as? String ?? "",
                source: element["source"] as? String ?? "yolo",
                confidence: element["conf"] as? Double ?? 0
            )
        }
    }

    private func candidatesWithResolvedLabels(_ candidates: [Candidate]) -> [Candidate] {
        let ocrCandidates = candidates.filter {
            $0.source == "ocr" && !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        return candidates.map { candidate in
            let trimmedLabel = candidate.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedLabel.isEmpty,
                  let resolvedLabel = bestOCRLabel(for: candidate, ocrCandidates: ocrCandidates) else {
                return candidate
            }

            return Candidate(
                screenshotRect: candidate.screenshotRect,
                label: resolvedLabel,
                source: candidate.source,
                confidence: candidate.confidence
            )
        }
    }

    private func bestOCRLabel(for candidate: Candidate, ocrCandidates: [Candidate]) -> String? {
        let expandedCandidateRect = candidate.screenshotRect.insetBy(dx: -10, dy: -8)
        let matchingOCRCandidates = ocrCandidates.compactMap { ocrCandidate -> (candidate: Candidate, score: CGFloat)? in
            let intersection = expandedCandidateRect.intersection(ocrCandidate.screenshotRect)
            let intersectionArea = max(0, intersection.width) * max(0, intersection.height)
            let ocrArea = max(1, ocrCandidate.screenshotRect.width * ocrCandidate.screenshotRect.height)
            let overlapRatio = intersectionArea / ocrArea
            let centerDistance = hypot(
                candidate.screenshotCenter.x - ocrCandidate.screenshotCenter.x,
                candidate.screenshotCenter.y - ocrCandidate.screenshotCenter.y
            )

            guard overlapRatio > 0.25 || centerDistance < max(candidate.screenshotRect.width, candidate.screenshotRect.height) * 0.9 else {
                return nil
            }

            let containmentBonus: CGFloat = candidate.screenshotRect.contains(ocrCandidate.screenshotCenter) ? 1000 : 0
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
            .filter {
                abs($0.screenshotRect.midY - bestOCRCandidate.screenshotRect.midY) < max(14, bestOCRCandidate.screenshotRect.height * 0.8)
            }
            .sorted { $0.screenshotRect.minX < $1.screenshotRect.minX }

        let joinedLabel = nearbyOCRCandidates
            .map(\.label)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return joinedLabel.isEmpty ? nil : joinedLabel
    }

    private func bestCandidate(
        matching query: String,
        candidates: [Candidate],
        proximityAnchorInScreenshotPixels: CGPoint?
    ) -> Candidate? {
        let scoredCandidates = candidates.compactMap { candidate -> (candidate: Candidate, score: Double)? in
            guard let labelScore = labelMatchScore(query: query, label: candidate.label) else {
                return nil
            }

            let sourceBonus = Double(sourcePriority(candidate.source))
            let confidenceBonus = min(candidate.confidence, 1.0) * 4.0
            let proximityPenalty: Double
            if let proximityAnchorInScreenshotPixels {
                let distance = hypot(
                    candidate.screenshotCenter.x - proximityAnchorInScreenshotPixels.x,
                    candidate.screenshotCenter.y - proximityAnchorInScreenshotPixels.y
                )
                proximityPenalty = min(distance / 120.0, 8.0)
            } else {
                proximityPenalty = 0
            }

            return (candidate, labelScore + sourceBonus + confidenceBonus - proximityPenalty)
        }

        return scoredCandidates.max { $0.score < $1.score }?.candidate
    }

    private func labelMatchScore(query: String, label: String) -> Double? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, !trimmedLabel.isEmpty else { return nil }

        let queryLower = trimmedQuery.lowercased()
        let labelLower = trimmedLabel.lowercased()
        let normalizedQuery = Self.normalize(trimmedQuery)
        let normalizedLabel = Self.normalize(trimmedLabel)
        let minimumSubstringLength = 3

        if queryLower == labelLower { return 100 }
        if normalizedQuery.full == normalizedLabel.full { return 92 }

        if queryLower.count >= 5,
           labelLower.count >= 5,
           (labelLower.contains(queryLower) || queryLower.contains(labelLower)) {
            return 72
        }

        if normalizedQuery.words.count == 1,
           normalizedLabel.words.count == 1,
           let queryWord = normalizedQuery.words.first,
           let labelWord = normalizedLabel.words.first,
           let fuzzyScore = Self.fuzzySingleWordLabelScore(query: queryWord, label: labelWord) {
            return fuzzyScore
        }

        let sharedWords = normalizedQuery.words
            .intersection(normalizedLabel.words)
            .filter { $0.count >= minimumSubstringLength }
        guard !sharedWords.isEmpty else { return nil }
        if normalizedQuery.words.count > 1,
           sharedWords.count < normalizedQuery.words.count {
            return nil
        }

        let coverage = Double(sharedWords.count) / Double(max(normalizedQuery.words.count, 1))
        if coverage >= 1.0 { return 58 }
        if coverage >= 0.5 { return 42 }
        return nil
    }

    private static func normalize(_ text: String) -> (full: String, words: Set<String>) {
        let lowercasedText = text.lowercased()
        let rawWords = lowercasedText.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let meaningfulWords = rawWords.filter { !stopWords.contains($0) }
        return (full: lowercasedText, words: Set(meaningfulWords.isEmpty ? rawWords : meaningfulWords))
    }

    private static func fuzzySingleWordLabelScore(query: String, label: String) -> Double? {
        guard min(query.count, label.count) >= 4,
              max(query.count, label.count) <= 16 else {
            return nil
        }

        let distance = editDistance(query, label)
        if distance == 1 { return 68 }
        if distance == 2, max(query.count, label.count) >= 8 { return 54 }
        return nil
    }

    private static func editDistance(_ firstText: String, _ secondText: String) -> Int {
        let firstCharacters = Array(firstText)
        let secondCharacters = Array(secondText)
        guard !firstCharacters.isEmpty else { return secondCharacters.count }
        guard !secondCharacters.isEmpty else { return firstCharacters.count }

        var previousRow = Array(0...secondCharacters.count)
        var currentRow = Array(repeating: 0, count: secondCharacters.count + 1)

        for firstIndex in 1...firstCharacters.count {
            currentRow[0] = firstIndex
            for secondIndex in 1...secondCharacters.count {
                let substitutionCost = firstCharacters[firstIndex - 1] == secondCharacters[secondIndex - 1] ? 0 : 1
                currentRow[secondIndex] = min(
                    previousRow[secondIndex] + 1,
                    currentRow[secondIndex - 1] + 1,
                    previousRow[secondIndex - 1] + substitutionCost
                )
            }
            previousRow = currentRow
        }

        return previousRow[secondCharacters.count]
    }

    private func screenshotPixelRectToGlobalScreen(
        _ pixelRect: CGRect,
        imageSize: CGSize,
        displayFrame: CGRect
    ) -> CGRect {
        let topLeft = screenshotPixelToGlobalScreen(
            CGPoint(x: pixelRect.minX, y: pixelRect.minY),
            imageSize: imageSize,
            displayFrame: displayFrame
        )
        let bottomRight = screenshotPixelToGlobalScreen(
            CGPoint(x: pixelRect.maxX, y: pixelRect.maxY),
            imageSize: imageSize,
            displayFrame: displayFrame
        )

        return CGRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(topLeft.y - bottomRight.y)
        )
    }

    private func screenshotPixelToGlobalScreen(
        _ pixel: CGPoint,
        imageSize: CGSize,
        displayFrame: CGRect
    ) -> CGPoint {
        let clampedX = max(0, min(pixel.x, imageSize.width))
        let clampedY = max(0, min(pixel.y, imageSize.height))
        let displayLocalX = clampedX * (displayFrame.width / max(imageSize.width, 1))
        let displayLocalY = clampedY * (displayFrame.height / max(imageSize.height, 1))

        return CGPoint(
            x: displayLocalX + displayFrame.origin.x,
            y: displayFrame.height - displayLocalY + displayFrame.origin.y
        )
    }

    private func globalScreenPointToScreenshotPixel(
        _ globalPoint: CGPoint,
        imageSize: CGSize,
        displayFrame: CGRect
    ) -> CGPoint {
        let displayLocalX = globalPoint.x - displayFrame.origin.x
        let displayLocalYFromBottom = globalPoint.y - displayFrame.origin.y
        let displayLocalYFromTop = displayFrame.height - displayLocalYFromBottom

        return CGPoint(
            x: displayLocalX * (imageSize.width / max(displayFrame.width, 1)),
            y: displayLocalYFromTop * (imageSize.height / max(displayFrame.height, 1))
        )
    }

    private func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let leftDistance = rect.minX - point.x
        let rightDistance = point.x - rect.maxX
        let topDistance = rect.minY - point.y
        let bottomDistance = point.y - rect.maxY
        let horizontalDistance = max(leftDistance, 0, rightDistance)
        let verticalDistance = max(topDistance, 0, bottomDistance)
        return hypot(horizontalDistance, verticalDistance)
    }

    private func normalizedBox2D(for screenshotRect: CGRect, imageSize: CGSize) -> [Int] {
        let y1 = Int((screenshotRect.minY * 1000 / max(imageSize.height, 1)).rounded())
        let x1 = Int((screenshotRect.minX * 1000 / max(imageSize.width, 1)).rounded())
        let y2 = Int((screenshotRect.maxY * 1000 / max(imageSize.height, 1)).rounded())
        let x2 = Int((screenshotRect.maxX * 1000 / max(imageSize.width, 1)).rounded())
        return [
            max(0, min(1000, y1)),
            max(0, min(1000, x1)),
            max(0, min(1000, y2)),
            max(0, min(1000, x2))
        ]
    }

    private func targetID(for candidate: Candidate) -> String {
        let rect = candidate.screenshotRect
        return [
            candidate.source,
            candidate.label,
            "\(Int(rect.minX))",
            "\(Int(rect.minY))",
            "\(Int(rect.maxX))",
            "\(Int(rect.maxY))"
        ].joined(separator: ":")
    }

    private static func array(from rect: CGRect) -> [Double] {
        [rect.minX, rect.minY, rect.maxX, rect.maxY]
    }

    private func sourcePriority(_ source: String) -> Int {
        if source == "ocr" { return 4 }
        return 1
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}
