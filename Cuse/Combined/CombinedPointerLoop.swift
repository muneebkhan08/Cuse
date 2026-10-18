//  CombinedPointerLoop.swift
//  Combined mode: Gemini Flash plans every step, Laya performs it.
//
//  Per step:
//    1. Fresh local CoreML/OCR/AX targets.
//    2. Gemini Flash plans the next action from the labels alone. If the labels
//       are not enough, the same step is re-planned with a screenshot attached
//       (only when the user's Screenshots toggle allows remote images).
//    3. Pointer actions: Laya ranks the detected boxes for Gemini's target
//       description. When Laya and Gemini agree the click happens immediately.
//       When they disagree Gemini re-checks, and must choose one of the two.
//    4. The shared engine moves the cursor, acts and validates the change.
//
//  Neither model invents coordinates: every click lands on a detected box.

import AppKit
import Foundation

@MainActor
final class CombinedPointerLoop {
    private let engine: CuseEngine
    private let layaClient: JevClient
    private let planner: GeminiFlashPlanner
    private let report: @MainActor (JevStepSnapshot) -> Void

    init(engine: CuseEngine,
         layaClient: JevClient = .shared,
         planner: GeminiFlashPlanner = .shared,
         report: @escaping @MainActor (JevStepSnapshot) -> Void) {
        self.engine = engine
        self.layaClient = layaClient
        self.planner = planner
        self.report = report
    }

    func run(task: String, app: String?, maxSteps: Int = 15) async -> JevPointerLoop.Outcome {
        var history: [String] = []
        var inputTokens = 0
        var snapshot = JevStepSnapshot(
            step: 0, task: task, detected: 0, done: 0, absent: 0, bars: [],
            actionKind: "click", note: "Looking at the screen", finished: false,
            milliseconds: 0, inputTokens: 0
        )
        func finish(ok: Bool = false, reason: String?, message: String) -> JevPointerLoop.Outcome {
            snapshot.finished = true
            snapshot.note = message
            report(snapshot)
            return JevPointerLoop.Outcome(ok: ok, reason: reason, message: message,
                                          steps: history.count, inputTokens: inputTokens)
        }
        // Gemini may legitimately switch apps (open_app), so the pinned app follows it.
        var currentTargetAppName = app
        func targetAppChanged() -> Bool {
            guard let currentTargetAppName, let frontmost = NSWorkspace.shared.frontmostApplication,
                  frontmost.bundleIdentifier != Bundle.main.bundleIdentifier else { return false }
            return frontmost.localizedName?.caseInsensitiveCompare(currentTargetAppName) != .orderedSame
        }
        let traceID = CuseActionTrace.makeID(source: "combined")

        // The final observation verifies the last allowed action without exceeding the action budget.
        for step in 1...(maxSteps + 1) {
            do {
                try Task.checkCancellation()
                if targetAppChanged() {
                    return finish(reason: "app_changed", message: "App changed. Start a new command in the app you want to use.")
                }
                let observation = engine.observe()
                guard observation.isCuaActionDriverEnabled else {
                    return finish(reason: "action_driver_disabled", message: "Enable desktop actions in Settings first.")
                }
                guard observation.isAutopilotEnabled else {
                    return finish(reason: "autopilot_disabled", message: "Enable auto-click to use Combined mode.")
                }

                let targetList = await engine.localPerceptionTargets(refresh: true, reason: "Combined step \(step)")
                try Task.checkCancellation()
                let plannerElements = targetList.targets.map { target in
                    CombinedPlannerElement(id: target.id, label: target.label, source: target.source,
                                           normalizedBox2D: target.normalizedBox2D)
                }
                let layaCandidates = targetList.targets.map { target in
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
                snapshot.step = step
                snapshot.detected = plannerElements.count
                snapshot.bars = []
                snapshot.note = "Gemini is planning from \(plannerElements.count) labels"
                report(snapshot)

                // Labels first: fast and no image leaves the Mac.
                var screenshotJPEGBase64: String?
                var planned = try await planner.plan(
                    task: task, history: history, appName: currentTargetAppName,
                    elements: plannerElements, screenshotJPEGBase64: nil
                )
                inputTokens += planned.inputTokens
                try Task.checkCancellation()

                if planned.decision.status == .needScreenshot {
                    screenshotJPEGBase64 = await screenshotForPlanner()
                    guard let screenshotJPEGBase64 else {
                        return finish(reason: "labels_insufficient",
                                      message: "Gemini needs to see the screen for this step. Turn on Screenshots in Settings and try again.")
                    }
                    snapshot.note = "Labels weren't enough, Gemini is looking at the screen"
                    report(snapshot)
                    planned = try await planner.plan(
                        task: task, history: history, appName: currentTargetAppName,
                        elements: plannerElements, screenshotJPEGBase64: screenshotJPEGBase64
                    )
                    inputTokens += planned.inputTokens
                    try Task.checkCancellation()
                }

                var plannerDecision = planned.decision
                snapshot.milliseconds = planned.milliseconds
                snapshot.inputTokens = inputTokens

                switch plannerDecision.status {
                case .done:
                    snapshot.done = 1
                    let summary = plannerDecision.message.isEmpty ? "Task complete" : plannerDecision.message
                    return finish(ok: true, reason: nil, message: "\(summary) (\(history.count) actions)")
                case .impossible:
                    return finish(reason: "planner_impossible",
                                  message: plannerDecision.message.isEmpty ? "Gemini found no way to continue from this screen." : plannerDecision.message)
                case .needScreenshot:
                    return finish(reason: "labels_insufficient",
                                  message: "Gemini couldn't identify the next control, even with a screenshot.")
                case .act:
                    break
                }

                guard step <= maxSteps else {
                    return finish(reason: "step_budget", message: "Stopped after \(maxSteps) actions.")
                }
                guard let plannedAction = plannerDecision.action else {
                    return finish(reason: "planner_malformed", message: "Gemini returned no action.")
                }
                snapshot.actionKind = plannedAction.rawValue
                let planPreview = plannerDecision.remainingPlan.first ?? plannedAction.rawValue

                let pointerActionRequest: PointerActionRequest
                let historyEntry: String

                if plannedAction.needsScreenTarget {
                    snapshot.note = "Gemini: \(planPreview) · Laya is matching"
                    report(snapshot)

                    guard let chosenCandidate = try await chooseScreenTarget(
                        plannerDecision: &plannerDecision,
                        plannedAction: plannedAction,
                        task: task,
                        history: history,
                        appName: currentTargetAppName,
                        plannerElements: plannerElements,
                        layaCandidates: layaCandidates,
                        screenshotJPEGBase64: &screenshotJPEGBase64,
                        inputTokens: &inputTokens,
                        snapshot: &snapshot
                    ) else {
                        return finish(reason: "target_unresolved",
                                      message: "Gemini and Laya couldn't agree on a visible control. Try naming the button or menu.")
                    }

                    snapshot.note = "\(plannedAction.rawValue): \(chosenCandidate.label)"
                    report(snapshot)
                    guard !targetAppChanged() else {
                        return finish(reason: "app_changed", message: "App changed. Stopped before clicking.")
                    }
                    pointerActionRequest = PointerActionRequest(
                        goal: task, app: currentTargetAppName,
                        actionType: WorkflowStep.StepType.normalized(from: plannedAction.rawValue),
                        targetLabel: chosenCandidate.label, targetID: chosenCandidate.id, targetMark: nil,
                        execute: true, allowScreenshotPlanning: false, validateStateChange: true, traceID: traceID
                    )
                    historyEntry = "\(plannedAction.rawValue) \(chosenCandidate.label): completed"
                } else {
                    // Typing, keys, shortcuts and app launches act on the focused element,
                    // so no box is chosen. The engine still delivers and validates them.
                    snapshot.note = "\(plannedAction.rawValue): \(plannerDecision.text)"
                    report(snapshot)
                    pointerActionRequest = PointerActionRequest(
                        goal: task, app: currentTargetAppName,
                        actionType: WorkflowStep.StepType.normalized(from: plannedAction.rawValue),
                        targetLabel: plannerDecision.text, targetID: nil, targetMark: nil,
                        execute: true, allowScreenshotPlanning: false, validateStateChange: true, traceID: traceID
                    )
                    let recordedText = plannedAction == .type ? "\"\(plannerDecision.text)\"" : plannerDecision.text
                    historyEntry = "\(plannedAction.rawValue) \(recordedText): completed"
                }

                let actionResult = await engine.runPointerAction(pointerActionRequest)
                try Task.checkCancellation()
                guard actionResult.ok, actionResult.workflowOutcome?.status == "completed" else {
                    return finish(reason: actionResult.reason ?? "action_not_completed",
                                  message: actionResult.message ?? "The action did not complete.")
                }
                if plannedAction == .openApp {
                    // Use the real app name, since Gemini may say "Chrome" for "Google Chrome".
                    currentTargetAppName = NSWorkspace.shared.frontmostApplication?.localizedName ?? plannerDecision.text
                }
                history.append(historyEntry)
            } catch is CancellationError {
                return finish(reason: "cancelled", message: "Stopped.")
            } catch {
                if Task.isCancelled { return finish(reason: "cancelled", message: "Stopped.") }
                return finish(reason: "combined_error", message: error.localizedDescription)
            }
        }
        return finish(reason: "step_budget", message: "Action limit reached.")
    }

    /// Laya ranks the detected boxes for Gemini's description. Agreement acts at once;
    /// disagreement gets one Gemini re-check that must pick one of the two proposals.
    private func chooseScreenTarget(
        plannerDecision: inout CombinedPlannerDecision,
        plannedAction: CombinedPlannerDecision.Action,
        task: String,
        history: [String],
        appName: String?,
        plannerElements: [CombinedPlannerElement],
        layaCandidates: [JevCandidate],
        screenshotJPEGBase64: inout String?,
        inputTokens: inout Int,
        snapshot: inout JevStepSnapshot
    ) async throws -> JevCandidate? {
        let geminiTargetLabel = plannerDecision.targetID.flatMap { targetID in
            layaCandidates.first(where: { $0.id == targetID })?.label
        }
        let layaStepInstruction = Self.layaStepInstruction(
            plannedAction: plannedAction,
            targetDescription: plannerDecision.targetDescription,
            geminiTargetLabel: geminiTargetLabel
        )
        guard let layaRequest = JevGrounding.request(
            task: layaStepInstruction, candidates: layaCandidates, history: history, excluding: [],
            // Gemini plans typing in Combined mode; Laya only places clicks here.
            allowTyping: false,
            useFocusedShortlist: true
        ) else { return nil }

        let (layaAnswers, layaMetrics) = try await layaClient.ask(state: layaRequest.state,
                                                                  questions: layaRequest.questions)
        try Task.checkCancellation()
        let layaDecision = try JevGrounding.decision(from: layaAnswers, pool: layaRequest.pool, metrics: layaMetrics)
        inputTokens += layaMetrics.inputTokens
        snapshot.inputTokens = inputTokens
        snapshot.done = layaDecision.done
        snapshot.absent = layaDecision.absent
        snapshot.milliseconds += layaMetrics.milliseconds

        let layaPickID = layaDecision.choseNone ? nil : layaDecision.best?.candidate.id
        let geminiPickID = plannerDecision.targetID
        snapshot.bars = layaDecision.ranked.prefix(5).map { entry in
            JevStepSnapshot.Bar(id: entry.candidate.id, label: entry.candidate.label,
                                probability: entry.probability,
                                isChosen: entry.candidate.id == (layaPickID ?? geminiPickID))
        }
        report(snapshot)

        // Look up every detected target, not just Laya's pool: with a focused
        // shortlist, Gemini's pick may be outside the few Laya was shown.
        let candidatesByID = Dictionary(JevGrounding.deduplicated(layaCandidates).map { ($0.id, $0) },
                                        uniquingKeysWith: { first, _ in first })
        // Gemini named nothing specific, so Laya's match is the only proposal.
        guard let geminiPickID else {
            return layaPickID.flatMap { candidatesByID[$0] }
        }
        if layaPickID == geminiPickID {
            return candidatesByID[geminiPickID]
        }

        // Disagreement: one re-check by Gemini, with the screen when allowed.
        let layaPickDescription = layaPickID.flatMap { candidatesByID[$0] }.map { "\($0.id) (\($0.label))" }
            ?? "no element (it found no match)"
        let geminiPickDescription = candidatesByID[geminiPickID].map { "\($0.id) (\($0.label))" } ?? geminiPickID
        snapshot.note = "Laya and Gemini disagree, re-checking"
        report(snapshot)
        if screenshotJPEGBase64 == nil {
            screenshotJPEGBase64 = await screenshotForPlanner()
        }
        let reviewNote = """
        Your previous answer targeted \(geminiPickDescription) for "\(plannerDecision.targetDescription)". \
        The local matcher Laya chose \(layaPickDescription). Look again and return status "act" with the same \
        action and target_id set to the element that is really correct. Use status "impossible" if neither is right.
        """
        let reviewed = try await planner.plan(
            task: task, history: history, appName: appName, elements: plannerElements,
            screenshotJPEGBase64: screenshotJPEGBase64, reviewNote: reviewNote
        )
        try Task.checkCancellation()
        inputTokens += reviewed.inputTokens
        snapshot.inputTokens = inputTokens
        snapshot.milliseconds += reviewed.milliseconds

        let allowedIDs = Set([geminiPickID, layaPickID].compactMap { $0 })
        guard reviewed.decision.status == .act,
              reviewed.decision.action == plannedAction,
              let reviewedID = reviewed.decision.targetID,
              allowedIDs.contains(reviewedID) else {
            return nil
        }
        plannerDecision = reviewed.decision
        snapshot.bars = snapshot.bars.map { bar in
            JevStepSnapshot.Bar(id: bar.id, label: bar.label, probability: bar.probability,
                                isChosen: bar.id == reviewedID)
        }
        return candidatesByID[reviewedID]
    }

    /// Laya answers "which element advances this task", so it gets only the
    /// current step. The overall goal would tempt it to jump ahead.
    static func layaStepInstruction(
        plannedAction: CombinedPlannerDecision.Action,
        targetDescription: String,
        geminiTargetLabel: String?
    ) -> String {
        let verb: String
        switch plannedAction {
        case .doubleClick: verb = "Double-click"
        case .rightClick: verb = "Right-click"
        default: verb = "Click"
        }
        let description = targetDescription.isEmpty ? (geminiTargetLabel.map { "\"\($0)\"" } ?? "the next control") : targetDescription
        if let geminiTargetLabel, !targetDescription.localizedCaseInsensitiveContains(geminiTargetLabel) {
            return "\(verb) \(description) (labelled \"\(geminiTargetLabel)\")"
        }
        return "\(verb) \(description)"
    }

    /// Cursor-screen JPEG for Gemini, or nil when the Screenshots toggle is off.
    private func screenshotForPlanner() async -> String? {
        let screenshotList = await engine.screenshots()
        guard screenshotList.ok else { return nil }
        let chosenScreenshot = screenshotList.screenshots.first(where: \.isCursorScreen) ?? screenshotList.screenshots.first
        guard let dataURL = chosenScreenshot?.dataURL,
              let base64StartIndex = dataURL.range(of: "base64,")?.upperBound else { return nil }
        return String(dataURL[base64StartIndex...])
    }
}
