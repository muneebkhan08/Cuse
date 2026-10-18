//  JevGrounding.swift
//  Turning a screen into one question, and an answer back into an action.
//
//  Deliberately free of Cuse types so it can be reasoned about and tested on
//  its own: callers map their detections into `JevCandidate` and map the result
//  back. Everything here is pure.

import CoreGraphics
import Foundation

// MARK: - Candidates

/// One thing on screen the loop is allowed to act on. Built from a detection —
/// never invented — so a decision can only ever name something real.
nonisolated struct JevCandidate: Equatable {
    let id: String
    let label: String
    let source: String          // "ocr" | "yolo" | "ax"
    let confidence: Double
    let centre: CGPoint         // global AppKit points, for the description only
    /// Coarse position such as "top-left", from `JevGrounding.screenRegion`.
    /// Laya reads words far more reliably than raw coordinates, so "the search
    /// box at the top" can be told apart from a footer link with the same text.
    var screenRegion: String = ""
    /// Whether this is a text or search field. Set from the box shape (see
    /// `JevGrounding.isTextFieldShaped`) and, for typing tasks, overridden by
    /// Accessibility's role, since a browser tab row has a field's shape too.
    var isTextFieldShaped: Bool = false

    /// How Jev reads this candidate. It cannot see pixels, so this string is
    /// the entire basis of the decision — label first, because the option key
    /// and value are both read semantically.
    var describedForJev: String {
        let shape = isTextFieldShaped ? " (wide text-field shape)" : ""
        let region = screenRegion.isEmpty ? "" : " in the \(screenRegion) of the screen"
        let location = centre == .zero ? "" : " at (\(Int(centre.x)),\(Int(centre.y)))"
        return "\(label.isEmpty ? "unlabeled element" : label) [\(source)]\(shape)\(region)\(location)"
    }
}

// MARK: - The decision

/// What one Jev call decided about one screen.
nonisolated struct JevDecision {
    /// Probability the task is already finished.
    let done: Double
    /// Probability that nothing on screen can advance the task.
    let absent: Double
    /// Candidates, most likely first. The `__none__` escape hatch is removed.
    let ranked: [(candidate: JevCandidate, probability: Double)]
    /// How to act on the winner: "click" | "double_click" | "right_click".
    let actionKind: String
    /// True when Jev's own top pick was the "none of these" option.
    let choseNone: Bool
    let metrics: JevCallMetrics

    var stopReason: String? {
        if choseNone { return "target_absent" }
        guard best != nil else { return "no_candidates" }
        return nil
    }

    var best: (candidate: JevCandidate, probability: Double)? { ranked.first }
}

// MARK: - Building the ask

nonisolated enum JevGrounding {
    /// The explicit escape hatch. Measured: without it, when the target is
    /// genuinely absent Jev still picks a wrong element at ~0.71 — high enough
    /// to look right and click. With it, true negatives score ~0.96 and true
    /// positives are unaffected.
    static let noneKey = "__none__"

    /// Leave headroom under the hard 255 cap.
    static let maxCandidates = 200

    static let doneThreshold = 0.70

    /// Gestures that act on the chosen screen element.
    static let pointerActionKinds: Set<String> = ["click", "double_click", "right_click"]
    /// Types the text quoted or named in the user's own task into the focused field.
    static let typeTextKind = "type_text"
    /// Presses Return to submit what was just typed.
    static let pressEnterKind = "press_enter"

    // MARK: - Screen position words

    /// "top-left", "middle-center", ... for a point inside its display.
    /// Global points use AppKit's bottom-left origin (the menu bar has the
    /// largest y), so the vertical fraction is flipped to read from the top.
    static func screenRegion(forCentre centre: CGPoint, displayFrame: CGRect) -> String {
        guard displayFrame.width > 0, displayFrame.height > 0 else { return "" }
        let horizontalFraction = (centre.x - displayFrame.minX) / displayFrame.width
        let verticalFraction = 1 - (centre.y - displayFrame.minY) / displayFrame.height
        let verticalWord = verticalFraction < 1.0 / 3.0 ? "top" : verticalFraction < 2.0 / 3.0 ? "middle" : "bottom"
        let horizontalWord = horizontalFraction < 1.0 / 3.0 ? "left" : horizontalFraction < 2.0 / 3.0 ? "center" : "right"
        return "\(verticalWord)-\(horizontalWord)"
    }

    // MARK: - Text field shape

    /// True for a detector (YOLO) box at least 150pt wide and 4x wider than
    /// tall. OCR boxes only cover the text itself, so they don't qualify.
    /// Measured on Wikipedia: the search field is 415x39, its button 70x34.
    /// `globalBox` is [minX, minY, maxX, maxY].
    static func isTextFieldShaped(source: String, globalBox: [Double]) -> Bool {
        guard source == "yolo", globalBox.count == 4 else { return false }
        let width = globalBox[2] - globalBox[0]
        let height = globalBox[3] - globalBox[1]
        return height > 0 && width >= 150 && width >= height * 4
    }

    /// While text is still waiting to be typed, the next click must land in a
    /// field. If a field-shaped candidate is within 0.10 of Laya's top pick,
    /// click it instead: on Wikipedia the field and the Search button were
    /// separated by only 0.02, and clicking the button lost the task.
    static let textFieldPreferenceMargin = 0.10

    static func preferringTextField(
        _ ranked: [(candidate: JevCandidate, probability: Double)]
    ) -> (candidate: JevCandidate, probability: Double)? {
        guard let best = ranked.first else { return nil }
        guard !best.candidate.isTextFieldShaped else { return best }
        return ranked.first { entry in
            entry.candidate.isTextFieldShaped && entry.probability >= best.probability - textFieldPreferenceMargin
        } ?? best
    }

    /// The text field the task is about, when one is unmistakable: a
    /// field-shaped box whose label shares a word with the task, like the
    /// "Search Wikipedia" box for "search for Alan Turing". The best match wins.
    /// In testing Laya chose a browser tab titled "Search - Wikipedia" over
    /// this field, so typing tasks go straight to the matching field.
    static func textFieldMatchingTask(_ candidates: [JevCandidate], task: String) -> JevCandidate? {
        let scores = relevanceScores(for: candidates, task: task)
        return candidates.indices
            .filter { candidates[$0].isTextFieldShaped && scores[$0] > 0 }
            .max { scores[$0] < scores[$1] }
            .map { candidates[$0] }
    }

    // MARK: - Relevance before the candidate cap

    private static let ignoredTaskWords: Set<String> = [
        "the", "a", "an", "to", "on", "in", "of", "for", "and", "then", "click", "open", "press",
        "tap", "select", "choose", "go", "button", "link", "menu", "please", "it", "into", "with", "at"
    ]

    private static func meaningfulWords(in text: String) -> Set<String> {
        Set(text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty && !ignoredTaskWords.contains($0) })
    }

    /// How strongly each candidate's label matches the task. A shared word
    /// counts 1 divided by how many labels on screen contain it, so a rare,
    /// specific word ("Deutsch", on one link) outweighs a common one
    /// ("Wikipedia", on nine). A label that appears whole in the task scores
    /// 1.5x. Unlabeled boxes score -1 so they sort last.
    static func relevanceScores(for candidates: [JevCandidate], task: String) -> [Double] {
        let taskWords = meaningfulWords(in: task)
        let lowercasedTask = task.lowercased()
        let wordsPerCandidate = candidates.map { meaningfulWords(in: $0.label) }
        var labelCountPerWord: [String: Int] = [:]
        for candidateWords in wordsPerCandidate {
            for word in candidateWords { labelCountPerWord[word, default: 0] += 1 }
        }
        return zip(candidates, wordsPerCandidate).map { candidate, candidateWords in
            let trimmedLabel = candidate.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmedLabel.isEmpty else { return -1 }
            let sharedWordWeight = candidateWords.intersection(taskWords)
                .reduce(0.0) { total, word in total + 1.0 / Double(labelCountPerWord[word] ?? 1) }
            let labelAppearsInTask = trimmedLabel.count >= 2 && lowercasedTask.contains(trimmedLabel)
            return sharedWordWeight * (labelAppearsInTask ? 1.5 : 1.0)
        }
    }

    /// Orders candidates so the ones whose labels match the task come first
    /// and unlabeled boxes come last. Busy pages produce ~300 detections but
    /// only `maxCandidates` are sent, so without this the control the user
    /// named could be cut off purely by detection order. Stable for ties.
    static func relevanceOrdered(_ candidates: [JevCandidate], task: String) -> [JevCandidate] {
        let scores = relevanceScores(for: candidates, task: task)
        return candidates.indices
            .sorted { lhs, rhs in scores[lhs] == scores[rhs] ? lhs < rhs : scores[lhs] > scores[rhs] }
            .map { candidates[$0] }
    }

    /// Smallest match score that counts as specific: the matched word is on at
    /// most about two labels.
    static let focusedShortlistMinimumScore = 0.5
    /// A weaker match still focuses Laya when it leaves only this many
    /// candidates, like the 4 "Search" labels on Wikipedia. Broader matches,
    /// like 9 "Wikipedia" labels, keep the full candidate list.
    static let focusedShortlistSmallCount = 6
    static let focusedShortlistMaximumCount = 20

    /// The few candidates that clearly match what the task names, or nil.
    ///
    /// Measured on a Wikipedia page with ~80 candidates: from the full list
    /// Laya picked a browser tab for "Click English" (0.33); from this
    /// shortlist it picked the English link (0.92). Specific matches only
    /// or small matches only (see `focusedShortlistMinimumScore` and
    /// `focusedShortlistSmallCount`), keeping those within half of the best
    /// score. If Laya answers "none" from a shortlist, the loop asks again
    /// with the full list, so a wrong shortlist can't strand a task.
    static func focusedShortlist(_ candidates: [JevCandidate], task: String) -> [JevCandidate]? {
        let scores = relevanceScores(for: candidates, task: task)
        guard let bestScore = scores.max(), bestScore > 0 else { return nil }
        let matchingIndices = candidates.indices
            .filter { scores[$0] >= bestScore * 0.5 }
            .sorted { scores[$0] > scores[$1] }
        guard bestScore >= focusedShortlistMinimumScore || matchingIndices.count <= focusedShortlistSmallCount else {
            return nil
        }
        let shortlist = matchingIndices.prefix(focusedShortlistMaximumCount).map { candidates[$0] }
        return shortlist.isEmpty ? nil : shortlist
    }

    // MARK: - Text the user asked to type

    /// The exact text the user asked to enter, copied from their task:
    /// quoted text first ("type 'hello world'"), otherwise the words after
    /// "search for", "type", "enter", "write" or "input", up to a joining word
    /// such as "and", "then", "on", "in". Laya never generates text itself.
    static func textToType(fromTask task: String) -> String? {
        let quotePairs: [(Character, Character)] = [("\"", "\""), ("\u{201C}", "\u{201D}"), ("'", "'"), ("\u{2018}", "\u{2019}")]
        for (openingQuote, closingQuote) in quotePairs {
            guard let openingIndex = task.firstIndex(of: openingQuote) else { continue }
            let afterOpening = task.index(after: openingIndex)
            guard let closingIndex = task[afterOpening...].firstIndex(of: closingQuote) else { continue }
            let quotedText = task[afterOpening..<closingIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if !quotedText.isEmpty { return quotedText }
        }

        let words = task.split(separator: " ").map(String.init)
        let lowercasedWords = words.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        let stopWords: Set<String> = ["and", "then", "on", "in", "into", "at", "using", "via", "from"]
        for (wordIndex, word) in lowercasedWords.enumerated() {
            var textStartIndex: Int?
            if word == "search", wordIndex + 1 < lowercasedWords.count, lowercasedWords[wordIndex + 1] == "for" {
                textStartIndex = wordIndex + 2
            } else if ["type", "enter", "write", "input"].contains(word) {
                textStartIndex = wordIndex + 1
            }
            guard let textStartIndex, textStartIndex < words.count else { continue }
            var collectedWords: [String] = []
            for candidateIndex in textStartIndex..<words.count {
                if stopWords.contains(lowercasedWords[candidateIndex]) { break }
                collectedWords.append(words[candidateIndex])
                if words[candidateIndex].hasSuffix(",") || words[candidateIndex].hasSuffix(".") { break }
            }
            let collectedText = collectedWords.joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: ",.").union(.whitespaces))
            if !collectedText.isEmpty { return collectedText }
        }
        return nil
    }

    // MARK: - Knowing when simple tasks are finished

    private static let singleActionVerbs: Set<String> = [
        "click", "open", "select", "tap", "press", "choose", "go", "show", "toggle",
        "check", "uncheck", "expand", "collapse", "close", "switch"
    ]

    /// True for one-step commands like "Click English" or "Open the Deutsch
    /// Wikipedia": a single action verb, no joining words, nothing to type.
    /// Laya's own "done" score is unreliable, so such tasks finish after one
    /// validated action instead of risking a second, unwanted click.
    static func isSingleActionTask(_ task: String) -> Bool {
        let lowercasedTask = " " + task.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) + " "
        let joiningMarkers = [" and ", " then ", ",", ";", " after ", " before "]
        guard !joiningMarkers.contains(where: { lowercasedTask.contains($0) }),
              textToType(fromTask: task) == nil,
              let firstWord = lowercasedTask.split(separator: " ").first else { return false }
        return singleActionVerbs.contains(String(firstWord))
    }

    /// True when the task ends with the text it asked to type, optionally
    /// followed by "press enter"/"hit return", as in "search for cats" or
    /// "click the search box and search for 'cats' then press enter". Such a
    /// task is finished once that text is typed and Return is pressed.
    static func taskEndsAfterSubmittingTypedText(_ task: String) -> Bool {
        guard let typedText = textToType(fromTask: task)?.lowercased() else { return false }
        var remainder = task.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let typedTextRange = remainder.range(of: typedText, options: .backwards) else { return false }
        remainder = String(remainder[typedTextRange.upperBound...])
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'\u{201D}\u{2019}.!").union(.whitespaces))
        let submitSuffixes = ["", "and press enter", "then press enter", "and hit enter", "and press return",
                              "then press return", "and hit return", "and search", "and submit"]
        return submitSuffixes.contains(remainder)
    }

    /// The gestures Laya may choose this step. Typing is offered only right
    /// after a click (the field must be focused first) and only once; Return
    /// only right after typing. While text is still waiting to be typed, only
    /// a single click is offered: double and right clicks never put text into
    /// a field and led Laya astray in testing.
    static func actionKindOptions(task: String, history: [String], allowTyping: Bool) -> [String: String] {
        var options: [String: String] = [
            "click": "A normal single left click — the default for buttons, menus, links, list rows, text fields",
            "double_click": "Double click — opening a file or folder from a list",
            "right_click": "Right click to open a context menu"
        ]
        guard allowTyping else { return options }
        let lastEntry = history.last ?? ""
        let lastActionWasClick = lastEntry.hasPrefix("click ") || lastEntry.hasPrefix("double_click ")
        let hasAlreadyTyped = history.contains { $0.hasPrefix(typeTextKind) }
        if let text = textToType(fromTask: task), !hasAlreadyTyped {
            options["double_click"] = nil
            options["right_click"] = nil
            if lastActionWasClick {
                options[typeTextKind] = "Type \"\(text)\" into the text field that was just clicked"
            }
        }
        if lastEntry.hasPrefix(typeTextKind) {
            options[pressEnterKind] = "Press Return to submit or search for the text that was just typed"
        }
        return options
    }

    /// Identical descriptions must be collapsed before asking: on a true tie
    /// Jev does not report 50/50, it breaks toward the first key and still
    /// reports high confidence, which would read as discrimination it did not do.
    static func deduplicated(_ candidates: [JevCandidate]) -> [JevCandidate] {
        var seen = Set<String>()
        var seenIDs = Set<String>()
        var kept: [JevCandidate] = []
        for candidate in candidates {
            let description = candidate.describedForJev
            if !candidate.id.isEmpty, candidate.id != noneKey, seenIDs.insert(candidate.id).inserted,
               seen.insert(description).inserted { kept.append(candidate) }
        }
        return kept
    }

    /// The whole ask for one loop step: one `choice` over the candidates plus
    /// three cheap companions. Bundled into one call because the state is
    /// billed once and latency scales with question count, not option count.
    static func request(
        task: String,
        candidates: [JevCandidate],
        history: [String],
        excluding: Set<String>,
        allowTyping: Bool = true,
        useFocusedShortlist: Bool = false
    ) -> (state: [String: Any], questions: [String: JevQuestion], pool: [JevCandidate])? {
        let eligibleCandidates = deduplicated(candidates).filter { !excluding.contains($0.id) }
        let focusedCandidates = useFocusedShortlist ? focusedShortlist(eligibleCandidates, task: task) : nil
        let pool = focusedCandidates ?? Array(relevanceOrdered(eligibleCandidates, task: task).prefix(maxCandidates))
        guard !pool.isEmpty else { return nil }

        var criteria = Dictionary(uniqueKeysWithValues: pool.map { ($0.id, $0.describedForJev) })
        criteria[noneKey] = "None of these would advance the task — the control needed is not on screen"

        // `state` and `criteria` must describe the same world: when an element
        // appeared in one but not the other, answers became unstable between
        // otherwise identical runs.
        let state: [String: Any] = [
            "task": task,
            "step": history.count + 1,
            "already_done": history.isEmpty ? ["nothing yet"] : history,
            "screen_elements": pool.map { ["id": $0.id, "describes": $0.describedForJev] }
        ]

        let questions: [String: JevQuestion] = [
            "done": .noul(
                instructions: "Has this task been completed?"
            ),
            "absent": .noul(
                instructions: "Is the control needed to make the next bit of progress on the task missing from the elements on screen?"
            ),
            "pick": .choice(
                instructions: "Which single element should be acted on next to make progress on the task: \"\(task)\"?",
                criteria: criteria
            ),
            "kind": .choice(
                instructions: "What should happen next: a gesture on that element, or typing/submitting text?",
                criteria: actionKindOptions(task: task, history: history, allowTyping: allowTyping)
            )
        ]
        return (state, questions, pool)
    }

    /// A near-tie must not turn a button into a double-click or right-click.
    /// Laya often splits those three gestures by only a few points.
    static func preferredActionKind(from answer: JevAnswer?) -> String? {
        guard let choice = answer?.choice else { return nil }
        // Typing and Return are only offered right after the step that needs
        // them, so they don't need the near-tie protection gestures do.
        guard pointerActionKinds.contains(choice), choice != "click",
              let probabilities = answer?.probabilities,
              let chosenProbability = probabilities[choice],
              let clickProbability = probabilities["click"],
              chosenProbability - clickProbability < 0.15 else {
            return choice
        }
        return "click"
    }

    /// Read one Jev response back into a decision.
    static func decision(
        from answers: [String: JevAnswer],
        pool: [JevCandidate],
        metrics: JevCallMetrics,
        allowedActionKinds: Set<String> = pointerActionKinds
    ) throws -> JevDecision {
        guard let pick = answers["pick"], let choice = pick.choice,
              choice == noneKey || pool.contains(where: { $0.id == choice }),
              let done = answers["done"]?.noul, (0...1).contains(done),
              let absent = answers["absent"]?.noul, (0...1).contains(absent),
              let actionKind = preferredActionKind(from: answers["kind"]),
              allowedActionKinds.contains(actionKind),
              let probabilities = pick.probabilities, !probabilities.isEmpty,
              probabilities.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              let chosenProbability = probabilities[choice],
              let maximumProbability = probabilities.values.max(),
              // Laya rounds each probability to 4 decimals after argmax, so the
              // reported choice can sit a rounding step under another option.
              abs(chosenProbability - maximumProbability) <= 0.001,
              probabilities.keys.allSatisfy({ key in key == noneKey || pool.contains(where: { $0.id == key }) }) else {
            throw JevError.malformed("incomplete or invalid decision")
        }
        let byID = Dictionary(uniqueKeysWithValues: pool.map { ($0.id, $0) })
        let ranked: [(candidate: JevCandidate, probability: Double)] = pick.ranked
            .sorted { lhs, rhs in
                if lhs.probability != rhs.probability { return lhs.probability > rhs.probability }
                if lhs.key == choice { return true }
                if rhs.key == choice { return false }
                return lhs.key < rhs.key
            }
            .compactMap { entry in
                guard let candidate = byID[entry.key] else { return nil }   // drops __none__
                return (candidate: candidate, probability: entry.probability)
            }
        return JevDecision(
            done: done,
            absent: absent,
            ranked: ranked,
            actionKind: actionKind,
            choseNone: choice == noneKey,
            metrics: metrics
        )
    }
}

