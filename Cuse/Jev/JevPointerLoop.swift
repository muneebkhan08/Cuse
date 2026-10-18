import AppKit
import Foundation

struct JevStepSnapshot: Equatable {
    struct Bar: Equatable, Identifiable {
        let id: String
        let label: String
        let probability: Double
        let isChosen: Bool
    }

    var step: Int
    var task: String
    var detected: Int
    var done: Double
    var absent: Double
    var bars: [Bar]
    var actionKind: String
    var note: String            // what just happened, one short line
    var finished: Bool
    var milliseconds: Int
    var inputTokens: Int
}

/// JEV selects from fresh local targets; the shared engine owns execution and validation.
@MainActor
final class JevPointerLoop {
    private let engine: CuseEngine
    private let client: JevClient
    private let report: @MainActor (JevStepSnapshot) -> Void

    init(engine: CuseEngine, client: JevClient = .shared,
         report: @escaping @MainActor (JevStepSnapshot) -> Void) {
        self.engine = engine
        self.client = client
        self.report = report
    }

    struct Outcome {
        let ok: Bool
        let reason: String?
        let message: String
        let steps: Int
        let inputTokens: Int
    }

    /// Accessibility roles that accept typed text.
    private static let textInputRoles: Set<String> = ["AXTextField", "AXSearchField", "AXTextArea", "AXComboBox"]

    /// What Accessibility says is under a candidate: true for a text input,
    /// false for anything else (a browser tab, a button), nil when the app
    /// exposes nothing there. Box shape can't tell a search field from a tab
    /// row (both are wide and short); in testing a tab won that way.
    private static func isTextInputAccordingToAccessibility(atGlobalAppKitPoint point: CGPoint) -> Bool? {
        guard let primaryScreen = NSScreen.screens.first else { return nil }
        // AppKit global points grow upward from the primary screen's bottom;
        // Accessibility uses Core Graphics points growing downward from its top.
        let coreGraphicsY = primaryScreen.frame.maxY - point.y
        let systemWideElement = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWideElement, 0.2)
        var elementAtPoint: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWideElement, Float(point.x), Float(coreGraphicsY),
                                               &elementAtPoint) == .success,
              let elementAtPoint else { return nil }
        var roleValue: CFTypeRef?
        var subroleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(elementAtPoint, kAXRoleAttribute as CFString, &roleValue)
        AXUIElementCopyAttributeValue(elementAtPoint, kAXSubroleAttribute as CFString, &subroleValue)
        guard let role = roleValue as? String else { return nil }
        return textInputRoles.contains(role) || (subroleValue as? String) == "AXSearchField"
    }

    /// For a typing task, replaces the shape guess with Accessibility's answer
    /// on the candidates that could matter (field-shaped or matching the task),
    /// at most 16 lookups so a busy page stays fast.
    private static func confirmingTextInputs(_ candidates: [JevCandidate], task: String) -> [JevCandidate] {
        let scores = JevGrounding.relevanceScores(for: candidates, task: task)
        let indicesToCheck = candidates.indices
            .filter { candidates[$0].isTextFieldShaped || scores[$0] > 0 }
            .sorted { scores[$0] > scores[$1] }
            .prefix(16)
        var confirmedCandidates = candidates
        for candidateIndex in indicesToCheck {
            if let isTextInput = isTextInputAccordingToAccessibility(atGlobalAppKitPoint: candidates[candidateIndex].centre) {
                confirmedCandidates[candidateIndex].isTextFieldShaped = isTextInput
            }
        }
        return confirmedCandidates
    }

    /// Ends a history entry for a click that only focused a text field, so the
    /// next step knows to type. It still reads as a click to `actionKindOptions`.
    private static let focusedFieldHistoryMarker = " (text field): completed"

    /// Types text or presses a key on the focused element through the engine.
    /// Returns false when the engine did not complete the step.
    private func runTargetlessStep(
        _ actionType: WorkflowStep.StepType,
        text: String,
        task: String,
        app: String?,
        traceID: String,
        snapshot: inout JevStepSnapshot
    ) async throws -> Bool {
        snapshot.actionKind = actionType == .type ? JevGrounding.typeTextKind : JevGrounding.pressEnterKind
        snapshot.note = actionType == .type ? "typing \"\(text)\"" : "pressing \(text)"
        report(snapshot)
        let result = await engine.runPointerAction(PointerActionRequest(
            goal: task, app: app, actionType: actionType,
            targetLabel: text, targetID: nil, targetMark: nil,
            execute: true, allowScreenshotPlanning: false, validateStateChange: true, traceID: traceID
        ))
        try Task.checkCancellation()
        return result.ok && result.workflowOutcome?.status == "completed"
    }

    func run(task: String, app: String?, maxSteps: Int = 12) async -> Outcome {
        var history: [String] = []
        var inputTokens = 0
        var snapshot = JevStepSnapshot(
            step: 0, task: task, detected: 0, done: 0, absent: 0, bars: [],
            actionKind: "click", note: "Looking at the screen", finished: false,
            milliseconds: 0, inputTokens: 0
        )
        func finish(ok: Bool = false, reason: String?, message: String) -> Outcome {
            snapshot.finished = true
            snapshot.note = message
            report(snapshot)
            return Outcome(ok: ok, reason: reason, message: message, steps: history.count, inputTokens: inputTokens)
        }
        guard maxSteps > 0 else {
            return finish(reason: "step_budget", message: "No actions allowed.")
        }
        func targetAppChanged() -> Bool {
            guard let app, let frontmost = NSWorkspace.shared.frontmostApplication,
                  frontmost.bundleIdentifier != Bundle.main.bundleIdentifier else { return false }
            return frontmost.localizedName?.caseInsensitiveCompare(app) != .orderedSame
        }
        let traceID = CuseActionTrace.makeID(source: "jev")
        // The final observation verifies the last allowed action without exceeding the action budget.
        for step in 1...(maxSteps + 1) {
            do {
                try Task.checkCancellation()
                guard !targetAppChanged() else {
                    return finish(reason: "app_changed", message: "App changed. Start a new Laya command in the app you want to use.")
                }
                let observation = engine.observe()
                guard observation.isCuaActionDriverEnabled else {
                    return finish(reason: "action_driver_disabled", message: "Enable desktop actions in Settings first.")
                }
                guard observation.isAutopilotEnabled else {
                    return finish(reason: "autopilot_disabled", message: "Enable auto-click to use Laya. Gemini also supports point-only guidance.")
                }
                let list = await engine.localPerceptionTargets(refresh: true, reason: "JEV step \(step)")
                try Task.checkCancellation()
                let detectedCandidates = list.targets.map { target in
                    let centre = CGPoint(x: target.globalCenter.first ?? 0,
                                         y: target.globalCenter.dropFirst().first ?? 0)
                    let displayFrame = target.displayFrame.count == 4
                        ? CGRect(x: target.displayFrame[0], y: target.displayFrame[1],
                                 width: target.displayFrame[2], height: target.displayFrame[3])
                        : .zero
                    return JevCandidate(
                        id: target.id, label: target.label, source: target.source,
                        confidence: target.confidence, centre: centre,
                        screenRegion: JevGrounding.screenRegion(forCentre: centre, displayFrame: displayFrame),
                        isTextFieldShaped: JevGrounding.isTextFieldShaped(source: target.source, globalBox: target.globalBox)
                    )
                }
                // Typing tasks must click a real text input, so ask Accessibility.
                let candidates = JevGrounding.textToType(fromTask: task) == nil
                    ? detectedCandidates
                    : Self.confirmingTextInputs(detectedCandidates, task: task)
                snapshot.step = step
                snapshot.detected = candidates.count

                // A typing task with an unmistakable matching field runs as a
                // fixed sequence: click the field, type the task's text, press
                // Return. Laya still decides when no field matches.
                let textToType = JevGrounding.textToType(fromTask: task)
                let hasTyped = history.contains { $0.hasPrefix(JevGrounding.typeTextKind) }
                let lastEntry = history.last ?? ""
                if let textToType, !hasTyped, step <= maxSteps {
                    if lastEntry.hasSuffix(Self.focusedFieldHistoryMarker) {
                        guard try await runTargetlessStep(.type, text: textToType, task: task, app: app,
                                                          traceID: traceID, snapshot: &snapshot) else {
                            return finish(reason: "action_not_completed", message: "Typing \"\(textToType)\" did not complete.")
                        }
                        history.append("\(JevGrounding.typeTextKind) \"\(textToType)\": completed")
                        continue
                    }
                    if let matchingField = JevGrounding.textFieldMatchingTask(candidates, task: task) {
                        snapshot.note = "click: \(matchingField.label) (text field)"
                        report(snapshot)
                        guard !targetAppChanged() else {
                            return finish(reason: "app_changed", message: "App changed. Laya stopped before clicking.")
                        }
                        // Focusing a field barely changes the screen; the typing step is validated instead.
                        let focusResult = await engine.runPointerAction(PointerActionRequest(
                            goal: task, app: app, actionType: .click,
                            targetLabel: matchingField.label, targetID: matchingField.id, targetMark: nil,
                            execute: true, allowScreenshotPlanning: false, validateStateChange: false, traceID: traceID
                        ))
                        try Task.checkCancellation()
                        guard focusResult.ok, focusResult.workflowOutcome?.status == "completed" else {
                            return finish(reason: focusResult.reason ?? "action_not_completed",
                                          message: focusResult.message ?? "Clicking the text field did not complete.")
                        }
                        history.append("click \(matchingField.label)\(Self.focusedFieldHistoryMarker)")
                        continue
                    }
                }
                if hasTyped, lastEntry.hasPrefix(JevGrounding.typeTextKind),
                   JevGrounding.taskEndsAfterSubmittingTypedText(task) {
                    guard try await runTargetlessStep(.pressKey, text: "Return", task: task, app: app,
                                                      traceID: traceID, snapshot: &snapshot) else {
                        return finish(reason: "action_not_completed", message: "Pressing Return did not complete.")
                    }
                    history.append("\(JevGrounding.pressEnterKind): completed")
                    return finish(ok: true, reason: nil, message: "Done: typed and submitted the text after \(history.count) actions.")
                }
                guard let fullRequest = JevGrounding.request(
                    task: task, candidates: candidates, history: history, excluding: []
                ) else {
                    return finish(reason: "no_local_targets", message: "No visible targets found. Check screen permissions and try again.")
                }
                // Laya is far more accurate choosing among the few targets whose
                // labels match the task than among ~100 (see focusedShortlist).
                let focusedRequest = JevGrounding.focusedShortlist(JevGrounding.deduplicated(candidates), task: task) == nil
                    ? nil
                    : JevGrounding.request(task: task, candidates: candidates, history: history,
                                           excluding: [], useFocusedShortlist: true)
                var request = focusedRequest ?? fullRequest
                snapshot.note = focusedRequest == nil
                    ? "Laya is choosing from \(candidates.count) targets"
                    : "Laya is choosing among \(request.pool.count) matching targets"
                report(snapshot)
                let offeredActionKinds = Set(JevGrounding.actionKindOptions(task: task, history: history, allowTyping: true).keys)
                var (answers, metrics) = try await client.ask(state: request.state, questions: request.questions)
                try Task.checkCancellation()
                var decision = try JevGrounding.decision(from: answers, pool: request.pool, metrics: metrics,
                                                         allowedActionKinds: offeredActionKinds)
                if focusedRequest != nil, decision.choseNone,
                   JevGrounding.pointerActionKinds.contains(decision.actionKind),
                   decision.done < JevGrounding.doneThreshold {
                    // None of the matching labels fits, so the control is
                    // described differently on screen: ask again with every target.
                    inputTokens += metrics.inputTokens
                    request = fullRequest
                    snapshot.note = "Laya is choosing from all \(candidates.count) targets"
                    report(snapshot)
                    (answers, metrics) = try await client.ask(state: request.state, questions: request.questions)
                    try Task.checkCancellation()
                    decision = try JevGrounding.decision(from: answers, pool: request.pool, metrics: metrics,
                                                         allowedActionKinds: offeredActionKinds)
                }
                inputTokens += metrics.inputTokens
                snapshot.done = decision.done
                snapshot.absent = decision.absent
                snapshot.inputTokens = inputTokens
                snapshot.milliseconds = metrics.milliseconds
                snapshot.actionKind = decision.actionKind
                snapshot.bars = decision.ranked.prefix(5).map { entry in
                    JevStepSnapshot.Bar(id: entry.candidate.id, label: entry.candidate.label,
                        probability: entry.probability, isChosen: entry.candidate.id == decision.best?.candidate.id)
                }
                // A task that names text to enter isn't finished until that text
                // was typed; Laya's done score has ended such tasks early.
                let isStillWaitingToType = JevGrounding.textToType(fromTask: task) != nil
                    && !history.contains { $0.hasPrefix(JevGrounding.typeTextKind) }
                if decision.done >= JevGrounding.doneThreshold, !isStillWaitingToType {
                    return finish(ok: true, reason: nil, message: "Laya reports the task complete after \(history.count) actions.")
                }
                guard step <= maxSteps || JevGrounding.pointerActionKinds.contains(decision.actionKind) else {
                    return finish(reason: "step_budget", message: "Stopped after \(maxSteps) actions.")
                }
                // Typing and Return act on the field that was just clicked, so
                // they don't need a screen element and run through the engine
                // as targetless steps with the user's own text.
                if decision.actionKind == JevGrounding.typeTextKind || decision.actionKind == JevGrounding.pressEnterKind {
                    let isTyping = decision.actionKind == JevGrounding.typeTextKind
                    guard let textOrKey = isTyping ? JevGrounding.textToType(fromTask: task) : "Return" else {
                        return finish(reason: "no_text_to_type", message: "Laya found no text to type in the task.")
                    }
                    snapshot.note = isTyping ? "typing \"\(textOrKey)\"" : "pressing Return"
                    report(snapshot)
                    guard !targetAppChanged() else {
                        return finish(reason: "app_changed", message: "App changed. Laya stopped before typing.")
                    }
                    let typingResult = await engine.runPointerAction(PointerActionRequest(
                        goal: task, app: app,
                        actionType: isTyping ? .type : .pressKey,
                        targetLabel: textOrKey, targetID: nil, targetMark: nil,
                        execute: true, allowScreenshotPlanning: false, validateStateChange: true, traceID: traceID
                    ))
                    try Task.checkCancellation()
                    guard typingResult.ok, typingResult.workflowOutcome?.status == "completed" else {
                        return finish(reason: typingResult.reason ?? "action_not_completed",
                                      message: typingResult.message ?? "Typing did not complete.")
                    }
                    history.append(isTyping ? "\(JevGrounding.typeTextKind) \"\(textOrKey)\": completed"
                                            : "\(JevGrounding.pressEnterKind): completed")
                    if !isTyping, JevGrounding.taskEndsAfterSubmittingTypedText(task) {
                        return finish(ok: true, reason: nil, message: "Done: typed and submitted the text after \(history.count) actions.")
                    }
                    continue
                }
                if let reason = decision.stopReason {
                    let message = reason == "target_absent"
                        ? "Laya couldn't find the requested control among \(candidates.count) targets. Name a visible button or menu."
                        : "No target is available to click."
                    return finish(reason: reason, message: message)
                }
                guard step <= maxSteps else {
                    return finish(reason: "step_budget", message: "Stopped after \(maxSteps) actions.")
                }
                let chosenEntry = isStillWaitingToType && decision.actionKind == "click"
                    ? JevGrounding.preferringTextField(decision.ranked)
                    : decision.best
                guard let chosen = chosenEntry else {
                    return finish(reason: "no_candidates", message: "No target to act on.")
                }
                snapshot.note = "\(decision.actionKind): \(chosen.candidate.label)"
                report(snapshot)
                guard !targetAppChanged() else {
                    return finish(reason: "app_changed", message: "App changed. Laya stopped before clicking.")
                }
                // Clicking into a text field barely changes the screen (only a
                // caret appears), so the engine's change check reads it as a
                // missed click. When that click is only there to focus the field
                // for typing, the typing step that follows is validated instead.
                let isFocusingClickBeforeTyping = isStillWaitingToType && decision.actionKind == "click"
                let result = await engine.runPointerAction(PointerActionRequest(
                    goal: task, app: app,
                    actionType: WorkflowStep.StepType.normalized(from: decision.actionKind),
                    targetLabel: chosen.candidate.label, targetID: chosen.candidate.id, targetMark: nil,
                    execute: true, allowScreenshotPlanning: false,
                    validateStateChange: !isFocusingClickBeforeTyping, traceID: traceID
                ))
                try Task.checkCancellation()
                guard result.ok, result.workflowOutcome?.status == "completed" else {
                    return finish(reason: result.reason ?? "action_not_completed", message: result.message ?? "The action did not complete.")
                }
                history.append("\(decision.actionKind) \(chosen.candidate.label): completed")
                if history.count == 1, JevGrounding.isSingleActionTask(task) {
                    return finish(ok: true, reason: nil, message: "Done: \(decision.actionKind) \(chosen.candidate.label).")
                }
                // The engine already waits for settlement and validates the action.
            } catch is CancellationError {
                return finish(reason: "cancelled", message: "Stopped.")
            } catch {
                if Task.isCancelled { return finish(reason: "cancelled", message: "Stopped.") }
                return finish(reason: "jev_error", message: error.localizedDescription)
            }
        }
        return finish(reason: "step_budget", message: "Action limit reached.")
    }
}
