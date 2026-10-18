//
//  WorkflowRunner.swift
//  Cuse
//
//  Executes one WorkflowPlan action at a time:
//    • Resolves the active step's element via ElementResolver and flies
//      the cursor there.
//    • Arms ClickDetector on the resolved target (preferring the real
//      AX rect over a fixed radius) so a real user click advances the
//      current action automatically in Teaching mode.
//    • Retries resolution with a budget instead of giving up silently
//      when an element hasn't appeared yet — a menu that's still
//      animating open should not stall the runner.
//    • Stamps every plan with a fresh `operationToken` (UUID) so a
//      stale advance callback firing after a rapid restart cannot move
//      a different plan forward.
//    • Pauses automatically when the user Cmd-Tabs to an unrelated
//      app, when a modal sheet/dialog appears mid-workflow, or when
//      the post-click AX-tree hash didn't change at all (the click
//      almost certainly missed).
//
//  These robustness behaviors are deliberate ports of the
//  Planner/Executor/Validator triad pattern: the executor is the
//  cursor flight + click arm, the validator is the post-click AX-hash
//  diff. We don't have a full external planner — Gemini emits the
//  whole plan up-front — but the validator boundary still buys us
//  cheap reliability without an extra LLM call on the hot path.
//

import AppKit
import ApplicationServices
import Combine
import Foundation

@MainActor
final class WorkflowRunner: ObservableObject {

    static let shared = WorkflowRunner()

    /// The currently-active plan, or nil if no workflow is running.
    @Published private(set) var activePlan: WorkflowPlan?

    /// Which step is currently highlighted (0-indexed). Advances when
    /// ClickDetector sees the user click the armed target, when the
    /// user taps "Skip", or when resolution succeeds on a retry.
    @Published private(set) var activeStepIndex: Int = 0

    /// True while we're mid-resolve on a step — used by the UI to show
    /// a subtle "looking for next element..." indicator instead of
    /// making the row look stuck.
    @Published private(set) var isResolvingCurrentStep: Bool = false

    /// Non-nil when the current step failed to resolve after the full
    /// retry budget. Surfaces a "couldn't find: X — skip?" prompt so
    /// the user isn't stranded.
    @Published private(set) var currentStepResolutionFailureLabel: String?

    /// When non-nil, the workflow is paused waiting for a specific
    /// external condition. The UI surfaces a resume button + the
    /// human-readable reason so the user always knows why nothing is
    /// happening.
    @Published private(set) var pausedReason: PauseReason?

    /// Why the current plan is paused (if it is). All of these are
    /// recoverable — the user can resume, skip, or stop the plan.
    enum PauseReason: Equatable {
        /// User Cmd-Tabbed to a different app while the plan was active.
        case userSwitchedToUnrelatedApp(bundleID: String)
        /// A sheet / modal dialog appeared and is blocking the next step.
        case modalDialogPresented(title: String?)
        /// The post-click AX-tree fingerprint didn't change — the click
        /// almost certainly missed its target.
        case postClickStateUnchanged(label: String)
        /// Teaching mode reached a step that requires synthetic input.
        case actionRequiresAutopilot(label: String)

        var humanReadable: String {
            switch self {
            case .userSwitchedToUnrelatedApp(let bundleID):
                return "switched to \(bundleID)"
            case .modalDialogPresented(let title):
                if let title, !title.isEmpty {
                    return "dialog appeared: \(title)"
                }
                return "dialog appeared"
            case .postClickStateUnchanged(let label):
                return "click on \"\(label)\" didn't seem to register"
            case .actionRequiresAutopilot(let label):
                return "\"\(label)\" needs Autopilot"
            }
        }
    }

    /// Remembered between `start` and subsequent `advance` calls so the
    /// click-driven auto-advance doesn't need the caller to re-thread
    /// these dependencies every step. Cleared on `stop`.
    private var pointHandlerForActivePlan: ((ElementResolver.Resolution) -> Void)?
    private var latestCaptureForActivePlan: CompanionScreenCapture?

    /// The previously-resolved step's global screen coordinate. Passed
    /// to `ElementResolver.resolve` as a proximity anchor so that when
    /// the current step's label (e.g. "New") matches multiple places
    /// on screen, we prefer the one closest to where the user just
    /// clicked — effectively "follow the menu chain" without modeling
    /// parent-child structure explicitly.
    private var previousStepResolvedGlobalScreenPoint: CGPoint?

    /// Cancels any in-flight resolution loop when the user skips, stops,
    /// or the plan advances for another reason.
    private var activeStepResolutionTask: Task<Void, Never>?

    /// Total budget for trying to find a step's element across retries.
    /// Covers animated menu opens, sheet transitions, and apps that take
    /// a beat to settle. We exit early the moment any strategy hits.
    private let stepResolutionTimeoutSeconds: Double = 3.5

    /// Short settle nap on the very first resolve attempt after a click
    /// fires the advance. Gives the click's effect (menu open, sheet
    /// appear) a moment to start rendering before we poll.
    private let postClickInitialSettleSeconds: Double = 0.08

    /// Time budget for each individual AX poll pass inside a retry.
    /// Kept short so we react to newly-appearing elements quickly.
    private let axPollTimeoutPerAttemptSeconds: Double = 0.9

    /// How long to wait after arming the click detector before
    /// auto-clicking on the user's behalf in Autopilot mode. Keep this
    /// short so harness-driven workflows feel responsive, while still
    /// leaving enough time for the overlay pointer to visibly lock on.
    private let autopilotClickDelayAfterArmingSeconds: Double = 0.28

    /// Closure that returns whether Autopilot mode is currently
    /// enabled. Injected from `CompanionManager` at app start so we
    /// don't have to import the manager here. nil = always-off
    /// (teaching mode), which is the safe default if start() is
    /// called before wiring.
    var isAutopilotEnabledProvider: (@MainActor () -> Bool)?

    /// Stamped at the start of every plan. Every async task captures
    /// this token by value and checks `currentOperationToken == captured`
    /// before mutating state — that's how we shrug off stale callbacks
    /// from a previous plan after a rapid restart.
    ///
    /// Without this, sequence:
    ///   1. plan A starts → resolves step 1, arms click detector
    ///   2. user immediately starts plan B before clicking
    ///   3. user clicks the armed-for-A target a second later
    ///   4. WITHOUT TOKEN: the A-resolution task advances B's step index
    ///   5. WITH TOKEN: the A callback sees the token mismatch and exits
    private var currentOperationToken: UUID?

    /// AX-tree fingerprint snapshotted just before we arm the click
    /// detector. Used by the post-click validator to decide whether
    /// the click actually changed UI state — if the hash is identical
    /// after the click, the click almost certainly missed.
    private var preClickAccessibilityFingerprint: String?

    /// Bundle ID of the app the active plan is targeting. Snapshotted
    /// at start so we can detect when the user switches away to an
    /// unrelated app (Slack, browser, etc.) and pause instead of
    /// blindly continuing to drive the cursor in the wrong app.
    private var planTargetAppBundleID: String?

    /// Cancellable on `NSWorkspace.didActivateApplicationNotification`.
    /// We only observe while a plan is active.
    private var appActivationObserver: NSObjectProtocol?

    /// The step that the cursor is currently pointed at. nil = no
    /// step is active (either no plan, or the plan has finished).
    var activeStep: WorkflowStep? {
        guard let plan = activePlan,
              activeStepIndex >= 0 && activeStepIndex < plan.steps.count else {
            return nil
        }
        return plan.steps[activeStepIndex]
    }

    /// Remaining steps after the current one — used for the UI preview.
    var upcomingSteps: [WorkflowStep] {
        guard let plan = activePlan else { return [] }
        let startIndex = activeStepIndex + 1
        guard startIndex < plan.steps.count else { return [] }
        return Array(plan.steps[startIndex...])
    }

    // MARK: - Start / Stop

    /// Begin executing one action. Resolves and points at step 1 immediately,
    /// using a freshly-captured screenshot rather than whatever was
    /// cached from Gemini Live's periodic updates. `pointHandler` is the
    /// closure that actually moves the cursor — injected so
    /// CompanionManager can own the overlay state.
    func start(
        plan: WorkflowPlan,
        pointHandler: @escaping (ElementResolver.Resolution) -> Void,
        latestCapture: CompanionScreenCapture?
    ) {
        let traceID = plan.traceID ?? CuseActionTrace.makeID(source: "workflow")
        let tracedPlan = plan.withTraceID(traceID)

        guard !tracedPlan.steps.isEmpty else {
            print("[Workflow] ignoring plan with no steps")
            recordWorkflowEvent(
                name: "start",
                status: "rejected",
                message: "Ignoring plan with no steps.",
                metadata: workflowPlanMetadata(tracedPlan)
            )
            return
        }

        let singleActionPlan: WorkflowPlan
        if tracedPlan.steps.count > 1 {
            print("[Workflow] ✂️ single-action mode: clamping \"\(tracedPlan.goal)\" from \(tracedPlan.steps.count) steps to 1")
            recordWorkflowEvent(
                name: "clamped",
                status: "warning",
                message: "WorkflowRunner accepts one action at a time.",
                metadata: workflowPlanMetadata(tracedPlan)
            )
            singleActionPlan = WorkflowPlan(
                goal: tracedPlan.goal,
                app: tracedPlan.app,
                steps: Array(tracedPlan.steps.prefix(1)),
                traceID: traceID,
                skipsPostClickStateCheck: tracedPlan.skipsPostClickStateCheck
            )
        } else {
            singleActionPlan = tracedPlan
        }

        activeStepResolutionTask?.cancel()
        let freshOperationToken = UUID()
        currentOperationToken = freshOperationToken
        activePlan = singleActionPlan
        activeStepIndex = 0
        currentStepResolutionFailureLabel = nil
        pausedReason = nil
        pointHandlerForActivePlan = pointHandler
        latestCaptureForActivePlan = latestCapture
        // Fresh plan — no prior step to bias toward, no fingerprint yet.
        previousStepResolvedGlobalScreenPoint = nil
        preClickAccessibilityFingerprint = nil
        planTargetAppBundleID = Self.bundleIDForAppName(singleActionPlan.app)
        startObservingAppActivationsForCurrentPlan()
        print("[Workflow] starting \"\(singleActionPlan.goal)\" — \(singleActionPlan.steps.count) step(s) — token=\(freshOperationToken.uuidString.prefix(8))")
        recordWorkflowEvent(
            name: "start",
            status: "started",
            metadata: workflowPlanMetadata(singleActionPlan).merging(
                [
                    "operation_token": String(freshOperationToken.uuidString.prefix(8)),
                    "latest_capture": latestCapture == nil ? "none" : "provided"
                ],
                uniquingKeysWith: { existing, _ in existing }
            )
        )

        // For step 1 the incoming `latestCapture` can be several seconds
        // stale (Gemini Live's periodic screenshot timer stops when we
        // close the session). Refresh first so resolution runs against
        // a current frame.
        activeStepResolutionTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshCaptureAndResolveActiveStep(
                isPostClick: false,
                operationToken: freshOperationToken
            )
        }
    }

    /// Update the cached screenshot used for step resolution. Called by
    /// CompanionManager when a fresh capture arrives so subsequent
    /// step transitions resolve against up-to-date pixels.
    func updateLatestCapture(_ capture: CompanionScreenCapture?) {
        latestCaptureForActivePlan = capture
    }

    /// Clear any active plan. Called when the user starts a new
    /// interaction or the session ends.
    func stop() {
        activeStepResolutionTask?.cancel()
        activeStepResolutionTask = nil
        currentOperationToken = nil
        stopObservingAppActivations()

        guard activePlan != nil else {
            ClickDetector.shared.disarm()
            isResolvingCurrentStep = false
            currentStepResolutionFailureLabel = nil
            pausedReason = nil
            return
        }
        let stoppedPlan = activePlan
        activePlan = nil
        activeStepIndex = 0
        isResolvingCurrentStep = false
        currentStepResolutionFailureLabel = nil
        pausedReason = nil
        pointHandlerForActivePlan = nil
        latestCaptureForActivePlan = nil
        previousStepResolvedGlobalScreenPoint = nil
        preClickAccessibilityFingerprint = nil
        planTargetAppBundleID = nil
        ClickDetector.shared.disarm()
        print("[Workflow] stopped")
        if let stoppedPlan {
            recordWorkflowEvent(
                name: "stop",
                status: "ok",
                metadata: workflowPlanMetadata(stoppedPlan)
            )
        }
    }

    // MARK: - Pause / Resume

    /// Pause the workflow with a human-readable reason. The cursor and
    /// click detector are deactivated until the user explicitly resumes
    /// or skips. Idempotent — pausing an already-paused plan with the
    /// same reason is a no-op.
    func pause(_ reason: PauseReason) {
        guard activePlan != nil else { return }
        if pausedReason == reason { return }
        print("[Workflow] paused — \(reason.humanReadable)")
        pausedReason = reason
        recordWorkflowEvent(
            name: "paused",
            status: "paused",
            message: reason.humanReadable,
            metadata: activeWorkflowMetadata()
        )
        ClickDetector.shared.disarm()
        activeStepResolutionTask?.cancel()
        activeStepResolutionTask = nil
        isResolvingCurrentStep = false
    }

    /// Re-resolve the current step from scratch. Used by the UI's
    /// "Resume" button when the user has dealt with the modal /
    /// switched back to the right app.
    func resume() {
        guard activePlan != nil, pausedReason != nil else { return }
        guard let token = currentOperationToken else { return }
        print("[Workflow] user resumed paused plan")
        recordWorkflowEvent(
            name: "resume",
            status: "started",
            metadata: activeWorkflowMetadata()
        )
        pausedReason = nil
        currentStepResolutionFailureLabel = nil
        activeStepResolutionTask?.cancel()
        activeStepResolutionTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshCaptureAndResolveActiveStep(
                isPostClick: false,
                operationToken: token
            )
        }
    }

    // MARK: - Advance / Skip

    /// Move to the next step and point the cursor at it. Called either
    /// by ClickDetector (when the user clicks the armed target) or
    /// externally by debug UI.
    func advance(
        pointHandler: @escaping (ElementResolver.Resolution) -> Void,
        latestCapture: CompanionScreenCapture?
    ) {
        pointHandlerForActivePlan = pointHandler
        latestCaptureForActivePlan = latestCapture
        advanceUsingCachedHandlers(isPostClick: false)
    }

    /// Explicitly skip the current step. Used by the "Skip" button in
    /// the panel UI and by the resolution-failure prompt. Treated
    /// identically to a successful advance so the runner keeps flowing.
    func skipCurrentStep() {
        print("[Workflow] user skipped step \(activeStepIndex + 1)")
        recordWorkflowEvent(
            name: "skip_step",
            status: "warning",
            metadata: activeWorkflowMetadata()
        )
        currentStepResolutionFailureLabel = nil
        pausedReason = nil
        advanceUsingCachedHandlers(isPostClick: false)
    }

    /// Retry resolving the current step from scratch — re-captures the
    /// screen and reruns the full resolver cascade. Used when an
    /// earlier attempt timed out and the user taps "Try again".
    func retryCurrentStep() {
        guard let token = currentOperationToken else { return }
        print("[Workflow] user retrying step \(activeStepIndex + 1)")
        recordWorkflowEvent(
            name: "retry_step",
            status: "started",
            metadata: activeWorkflowMetadata()
        )
        currentStepResolutionFailureLabel = nil
        pausedReason = nil
        activeStepResolutionTask?.cancel()
        activeStepResolutionTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshCaptureAndResolveActiveStep(
                isPostClick: false,
                operationToken: token
            )
        }
    }

    /// Advance using the pointHandler/capture cached when the plan
    /// started. This is what ClickDetector's callback uses.
    private func advanceUsingCachedHandlers(isPostClick: Bool) {
        guard let plan = activePlan else { return }
        guard currentOperationToken != nil else { return }
        guard pointHandlerForActivePlan != nil else {
            print("[Workflow] advance requested but no cached pointHandler — stopping")
            stop()
            return
        }

        // Validator hook — if a click was supposed to have happened,
        // did the screen actually change? An identical post-click AX
        // fingerprint after a brief settling window is a strong
        // signal the click missed its target. We give the target app
        // up to 350ms to update its AX tree before declaring "no
        // change" — without this window the validator races the
        // app's repaint and false-pauses on autopilot clicks where
        // we know the click fired only milliseconds ago.
        if isPostClick,
           shouldBypassPostClickValidator(plan: plan) {
            preClickAccessibilityFingerprint = nil
            continueAdvanceAfterValidator(plan: plan, isPostClick: true)
            return
        }

        if isPostClick,
           let preFingerprint = preClickAccessibilityFingerprint,
           let stepLabel = activeStep?.label {
            let token = currentOperationToken
            Task { [weak self] in
                guard let self else { return }
                let pollInterval: UInt64 = 80_000_000 // 80ms
                let maxAttempts = 5
                var didDetectChange = false
                for _ in 0..<maxAttempts {
                    if Task.isCancelled { return }
                    if token != self.currentOperationToken { return }
                    if let post = Self.captureAccessibilityFingerprint(
                        targetAppHint: plan.app
                    ), post != preFingerprint {
                        didDetectChange = true
                        break
                    }
                    try? await Task.sleep(nanoseconds: pollInterval)
                }
                guard token == self.currentOperationToken else { return }
                if didDetectChange {
                    self.preClickAccessibilityFingerprint = nil
                    self.continueAdvanceAfterValidator(plan: plan, isPostClick: true)
                } else {
                    print("[Workflow] ✗ post-click validator: AX fingerprint unchanged after settle window — pausing")
                    self.pause(.postClickStateUnchanged(label: stepLabel))
                }
            }
            return
        }
        // Always reset between steps so the next arm captures a fresh
        // pre-click snapshot.
        preClickAccessibilityFingerprint = nil
        continueAdvanceAfterValidator(plan: plan, isPostClick: isPostClick)
    }

    private func shouldBypassPostClickValidator(plan: WorkflowPlan) -> Bool {
        guard let currentStep = activeStep else { return false }

        if plan.skipsPostClickStateCheck == true {
            return true
        }

        if shouldSkipAccessibilityResolution(for: plan.app) {
            return true
        }

        // Context menus often do not mutate the target app's AX
        // fingerprint because the menu is represented outside the
        // app window. Let the next step resolve the menu item instead
        // of pausing immediately.
        if currentStep.type == .rightClick {
            return true
        }

        let nextStepIndex = activeStepIndex + 1
        guard plan.steps.indices.contains(nextStepIndex) else {
            return false
        }

        switch plan.steps[nextStepIndex].type {
        case .keyboardShortcut, .pressKey, .type, .setValue, .scroll:
            // Clicking into text or a focused control can be a valid
            // no-op at the AX-tree level. The following key/type action
            // is the real mutation, so don't block the flow here.
            return true
        default:
            return false
        }
    }

    /// Bottom half of `advanceUsingCachedHandlers` — extracted so the
    /// async validator can call it after its settle window without
    /// duplicating the step-increment logic. `isPostClick` is forwarded
    /// from the caller so post-click steps still get the brief settle
    /// nap before the next AX poll pass starts.
    private func continueAdvanceAfterValidator(plan: WorkflowPlan, isPostClick: Bool) {
        guard let token = currentOperationToken else { return }

        guard activeStepIndex + 1 < plan.steps.count else {
            print("[Workflow] plan complete")
            recordWorkflowEvent(
                name: "complete",
                status: "completed",
                metadata: workflowPlanMetadata(plan).merging(
                    ["completed_step_index": String(activeStepIndex + 1)],
                    uniquingKeysWith: { existing, _ in existing }
                )
            )
            stop()
            return
        }
        activeStepIndex += 1
        currentStepResolutionFailureLabel = nil
        activeStepResolutionTask?.cancel()
        activeStepResolutionTask = Task { [weak self] in
            guard let self else { return }
            // After a real click, the UI is mid-transition (menu opening,r
            // sheet appearing). Instead of blindly sleeping, give it a
            // very short nap to let the click register, then rely on   the
            // AX-polling retry budget inside the resolve loop to catch
            // the next element the moment it appears.
            if isPostClick {
                try? await Task.sleep(nanoseconds: UInt64(self.postClickInitialSettleSeconds * 1_000_000_000))
            }
            await self.refreshCaptureAndResolveActiveStep(
                isPostClick: isPostClick,
                operationToken: token
            )
        }
    }

    /// Capture a fresh screenshot of every connected display, then run
    /// the resolution loop on the active step. Polls AX for the element
    /// (up to the budget) so a menu that's animating open doesn't cause
    /// a silent stall. Token-gated so a stale task from a prior plan
    /// can't mutate state on the current one.
    private func refreshCaptureAndResolveActiveStep(
        isPostClick: Bool,
        operationToken: UUID
    ) async {
        guard operationToken == currentOperationToken else {
            print("[Workflow] ignoring stale resolve task — token mismatch")
            return
        }

        let freshCaptures = await Self.captureAllScreens()
        recordWorkflowEvent(
            name: "capture_for_resolution",
            status: freshCaptures.isEmpty ? "warning" : "ok",
            metadata: activeWorkflowMetadata().merging(
                [
                    "capture_count": String(freshCaptures.count),
                    "is_post_click": String(isPostClick)
                ],
                uniquingKeysWith: { existing, _ in existing }
            )
        )
        if let pickedCapture = freshCaptures.first(where: { $0.isCursorScreen }) ?? freshCaptures.first {
            latestCaptureForActivePlan = pickedCapture
        }

        // Modal-dialog gate: if the target app currently has a sheet or
        // dialog presented, the next step is unreachable behind it.
        // Pause + voice the dialog title so the user can deal with it
        // (an unsaved-changes prompt is the canonical example we never
        // want to dismiss automatically).
        if !isPostClick,
           let targetAppHint = activePlan?.app,
           let modalTitle = Self.detectBlockingModalDialogTitle(targetAppHint: targetAppHint) {
            print("[Workflow] modal dialog detected mid-workflow: \"\(modalTitle ?? "")\" — pausing")
            recordWorkflowEvent(
                name: "modal_detected",
                status: "paused",
                message: modalTitle,
                metadata: activeWorkflowMetadata()
            )
            pause(.modalDialogPresented(title: modalTitle))
            return
        }

        guard let step = activeStep else { return }

        // Non-click step types are only actionable when Autopilot is on
        // because there is no visible target to point at in Teaching mode.
        switch step.type {
        case .click, .rightClick, .doubleClick:
            guard let label = step.label, !label.isEmpty else {
                print("[Workflow] step \"\(step.hint)\" has no label — skipping")
                recordWorkflowEvent(
                    name: "step_missing_label",
                    status: "warning",
                    message: step.hint,
                    metadata: workflowStepMetadata(step).merging(
                        activeWorkflowMetadata(),
                        uniquingKeysWith: { existing, _ in existing }
                    )
                )
                advanceUsingCachedHandlers(isPostClick: false)
                return
            }
            await resolveActiveStepWithRetryBudget(
                label: label,
                allScreenCaptures: freshCaptures,
                isPostClick: isPostClick,
                operationToken: operationToken
            )

        case .openApp:
            await executeOpenApplicationStep(
                step: step,
                operationToken: operationToken
            )

        case .openURL:
            await executeOpenURLStep(
                step: step,
                operationToken: operationToken
            )

        case .keyboardShortcut:
            await executeKeyboardShortcutStep(
                step: step,
                operationToken: operationToken
            )

        case .pressKey:
            await executePressKeyStep(
                step: step,
                operationToken: operationToken
            )

        case .type:
            await executeTypeTextStep(
                step: step,
                operationToken: operationToken
            )

        case .setValue:
            await executeSetValueStep(
                step: step,
                operationToken: operationToken
            )

        case .scroll:
            await executeScrollStep(
                step: step,
                operationToken: operationToken
            )

        case .observe:
            guard let label = step.label, !label.isEmpty else {
                print("[Workflow] observe step \"\(step.hint)\" has no label — skipping")
                advanceUsingCachedHandlers(isPostClick: false)
                return
            }
            await resolveActiveStepWithRetryBudget(
                label: label,
                allScreenCaptures: freshCaptures,
                isPostClick: isPostClick,
                operationToken: operationToken
            )

        case .waitForState:
            print("[Workflow] step \"\(step.hint)\" is .waitForState — not yet implemented, skipping")
            advanceUsingCachedHandlers(isPostClick: false)
        }
    }

    /// Core of the "don't stall silently" fix. We try AX first (cheap,
    /// reruns quickly), then fall back to the model's box_2d on each new
    /// frame, for up to `stepResolutionTimeoutSeconds`. Exits early the
    /// moment any strategy finds the element. If nothing resolves in the
    /// budget, publishes a failure label the UI surfaces as
    /// "can't find X — skip?".
    private func resolveActiveStepWithRetryBudget(
        label: String,
        allScreenCaptures: [CompanionScreenCapture],
        isPostClick: Bool,
        operationToken: UUID
    ) async {
        isResolvingCurrentStep = true
        defer { isResolvingCurrentStep = false }

        let deadline = Date().addingTimeInterval(stepResolutionTimeoutSeconds)
        var latestAllCaptures = allScreenCaptures
        var attemptIndex = 0

        if let exactLocalResolution = ElementResolver.shared.exactLocalTargetResolution(
            targetID: activeStep?.targetID,
            targetMark: activeStep?.targetMark,
            fallbackLabel: label
        ) {
            recordWorkflowEvent(
                name: "resolved",
                status: "ok",
                metadata: activeWorkflowMetadata().merging(
                    resolutionMetadata(exactLocalResolution),
                    uniquingKeysWith: { existing, _ in existing }
                )
            )
            armCursorAndClickDetector(
                with: exactLocalResolution,
                pickingFrom: latestAllCaptures,
                stepType: activeStep?.type ?? .click,
                operationToken: operationToken
            )
            return
        }

        while Date() < deadline {
            if Task.isCancelled { return }
            if operationToken != currentOperationToken { return }
            attemptIndex += 1
            let activeStepHasSpatialHint = activeStep?.hintCoordinate != nil
                || activeStep?.box2DNormalized != nil

            // Pass 1: poll AX with a short budget. This is the fast path
            // for native apps and Electron — usually resolves in <100ms.
            // Canvas/no-AX apps like Blender skip this entirely so we
            // don't waste time repeatedly querying an empty tree before
            // using Gemini's box_2d.
            if !activeStepHasSpatialHint,
               !shouldSkipAccessibilityResolution(for: activePlan?.app) {
                if let axResolution = await ElementResolver.shared.pollAccessibilityTree(
                    label: label,
                    targetAppHint: activePlan?.app,
                    timeoutSeconds: axPollTimeoutPerAttemptSeconds
                ) {
                    if Task.isCancelled { return }
                    if operationToken != currentOperationToken { return }
                    recordWorkflowEvent(
                        name: "resolved",
                        status: "ok",
                        metadata: activeWorkflowMetadata().merging(
                            resolutionMetadata(axResolution).merging(
                                ["attempt": String(attemptIndex)],
                                uniquingKeysWith: { existing, _ in existing }
                            ),
                            uniquingKeysWith: { existing, _ in existing }
                        )
                    )
                    armCursorAndClickDetector(
                        with: axResolution,
                        pickingFrom: latestAllCaptures,
                        stepType: activeStep?.type ?? .click,
                        operationToken: operationToken
                    )
                    return
                }
            }

            // Pass 2: refresh the screenshot (app may have redrawn since
            // the last capture) and try Gemini's box_2d fallback.
            latestAllCaptures = await Self.captureAllScreens()
            let pickedCapture = latestAllCaptures.first(where: { $0.isCursorScreen }) ?? latestAllCaptures.first
            latestCaptureForActivePlan = pickedCapture

            if let capture = pickedCapture,
               let resolution = await ElementResolver.shared.resolve(
                   label: label,
                   llmHintInScreenshotPixels: activeStep?.hintCoordinate(in: capture),
                   latestCapture: capture,
                   targetAppHint: activePlan?.app,
                   proximityAnchorInGlobalScreen: previousStepResolvedGlobalScreenPoint,
                   preferLocalHintBeforeAccessibility: activeStepHasSpatialHint
               ) {
                if Task.isCancelled { return }
                if operationToken != currentOperationToken { return }
                var finalResolution = resolution
                let llmHintForCapture = activeStep?.hintCoordinate(in: capture)
                if let rejectionReason = canvasVisualObjectTextMatchRejectionReason(
                    resolution: resolution,
                    step: activeStep,
                    plan: activePlan
                ) {
                    if let llmHintForCapture {
                        let rawLLMResolution = ElementResolver.shared.rawLLMCoordinate(
                            label: label,
                            llmHintInScreenshotPixels: llmHintForCapture,
                            capture: capture
                        )
                        recordWorkflowEvent(
                            name: "resolution_fallback",
                            status: "warning",
                            message: rejectionReason,
                            metadata: activeWorkflowMetadata().merging(
                                resolutionMetadata(resolution).merging(
                                    [
                                        "attempt": String(attemptIndex),
                                        "capture_label": capture.label,
                                        "fallback_source": "llm_raw_coordinates",
                                        "reason": rejectionReason
                                    ],
                                    uniquingKeysWith: { existing, _ in existing }
                                ),
                                uniquingKeysWith: { existing, _ in existing }
                            )
                        )
                        finalResolution = rawLLMResolution
                    } else {
                        recordWorkflowEvent(
                            name: "resolve_failed",
                            status: "failed",
                            message: "Canvas object needs point_2d or box_2d.",
                            metadata: activeWorkflowMetadata().merging(
                                resolutionMetadata(resolution).merging(
                                    [
                                        "attempt": String(attemptIndex),
                                        "capture_label": capture.label,
                                        "reason": rejectionReason
                                    ],
                                    uniquingKeysWith: { existing, _ in existing }
                                ),
                                uniquingKeysWith: { existing, _ in existing }
                            )
                        )
                        currentStepResolutionFailureLabel = label
                        return
                    }
                }
                recordWorkflowEvent(
                    name: "resolved",
                    status: "ok",
                    metadata: activeWorkflowMetadata().merging(
                        resolutionMetadata(finalResolution).merging(
                            [
                                "attempt": String(attemptIndex),
                                "capture_label": capture.label
                            ],
                            uniquingKeysWith: { existing, _ in existing }
                        ),
                        uniquingKeysWith: { existing, _ in existing }
                    )
                )
                armCursorAndClickDetector(
                    with: finalResolution,
                    pickingFrom: latestAllCaptures,
                    stepType: activeStep?.type ?? .click,
                    operationToken: operationToken
                )
                return
            }

            // Didn't resolve yet — on a post-click retry the first couple
            // of attempts can miss because the UI is mid-animation. Short
            // wait before the next pass.
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        // Ran out of budget. Surface the failure so the UI can prompt
        // the user to skip or retry instead of stalling silently.
        guard operationToken == currentOperationToken else { return }
        print("[Workflow] ✗ step \(activeStepIndex + 1) \"\(label)\" did not resolve within \(stepResolutionTimeoutSeconds)s (\(attemptIndex) attempts)")
        recordWorkflowEvent(
            name: "resolve_failed",
            status: "failed",
            message: label,
            metadata: activeWorkflowMetadata().merging(
                [
                    "attempt_count": String(attemptIndex),
                    "timeout_seconds": String(format: "%.1f", stepResolutionTimeoutSeconds)
                ],
                uniquingKeysWith: { existing, _ in existing }
            )
        )
        currentStepResolutionFailureLabel = label
    }

    /// Once we have a resolution, snapshot the current AX fingerprint
    /// (so the validator can detect a no-op click), move the cursor,
    /// pick the right-monitor display frame, and arm the click detector
    /// with the tightest hit area available (AX rect when present,
    /// point + radius otherwise).
    private func armCursorAndClickDetector(
        with resolution: ElementResolver.Resolution,
        pickingFrom allScreenCaptures: [CompanionScreenCapture],
        stepType: WorkflowStep.StepType,
        operationToken: UUID
    ) {
        // Prefer the capture whose display actually contains the resolved
        // point — matters when the target is on a non-cursor monitor.
        if let matchingCapture = allScreenCaptures.first(where: {
            $0.displayFrame.contains(resolution.globalScreenPoint)
        }) {
            latestCaptureForActivePlan = matchingCapture
        }

        // Remember this step's resolved point so the NEXT step's
        // resolution can tie-break multiple label matches in favor of
        // the one closest to where we just clicked. That's how nested
        // menu resolution stays correct without modeling parent-child
        // structure — "New" near the just-opened File menu beats a
        // stray "New Tab" button elsewhere on screen.
        previousStepResolvedGlobalScreenPoint = resolution.globalScreenPoint

        if stepType == .observe {
            ClickDetector.shared.disarm()
            pointHandlerForActivePlan?(resolution)
            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: 650_000_000)
                guard operationToken == self.currentOperationToken else { return }
                self.advanceUsingCachedHandlers(isPostClick: false)
            }
            return
        }

        // Validator setup: snapshot the AX fingerprint of the target app
        // BEFORE the click happens. After the click fires advance, we'll
        // compare the post-click fingerprint to detect the click missed
        // (no-op) versus actually transitioned the UI.
        preClickAccessibilityFingerprint = shouldSkipAccessibilityResolution(for: activePlan?.app)
            ? nil
            : Self.captureAccessibilityFingerprint(targetAppHint: activePlan?.app)

        let isAutopilotEnabled = isAutopilotEnabledProvider?() ?? false
        if isAutopilotEnabled {
            ClickDetector.shared.disarm()
        } else {
            // Teaching mode: arm the detector BEFORE handing the cursor
            // the new resolution. The cursor flight takes ~500ms and a
            // fast user can click the real element during that window;
            // arming first closes the race.
            ClickDetector.shared.arm(
                targetPointInGlobalScreenCoordinates: resolution.globalScreenPoint,
                targetRectInGlobalScreenCoordinates: resolution.globalScreenRect,
                onTargetClicked: { [weak self] in
                    guard let self else { return }
                    // Token check shrugs off a stale arm whose plan was
                    // replaced before the user clicked.
                    guard operationToken == self.currentOperationToken else {
                        print("[Workflow] click landed on stale armed target — ignored (token mismatch)")
                        return
                    }
                    print("[Workflow] target click detected — advancing to next step")
                    self.advanceUsingCachedHandlers(isPostClick: true)
                }
            )
        }

        // Fly the cursor. Handler is cached so subsequent steps keep it.
        if let pointHandler = pointHandlerForActivePlan {
            pointHandler(resolution)
        }

        // Autopilot — click the resolved element on the user's behalf
        // after the cursor flight finishes. Token-gated so an autopilot
        // click from a stale plan can't hijack a newer one.
        scheduleAutopilotClickIfEnabled(
            resolution: resolution,
            stepType: stepType,
            operationToken: operationToken
        )
    }

    /// Schedule an auto-click after the cursor flight settles. No-op
    /// if Autopilot is disabled; that's the case where we're teaching
    /// and the user clicks themselves.
    private func scheduleAutopilotClickIfEnabled(
        resolution: ElementResolver.Resolution,
        stepType: WorkflowStep.StepType,
        operationToken: UUID
    ) {
        let isEnabled = isAutopilotEnabledProvider?() ?? false
        guard isEnabled else { return }

        let targetAppHint = activePlan?.app
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(
                nanoseconds: UInt64(self.autopilotClickDelayAfterArmingSeconds * 1_000_000_000)
            )
            // Token + still-active checks: if the plan was stopped or
            // replaced (e.g. user pressed the hotkey again, or
            // app-switch pause kicked in) during the delay, don't
            // click stale state.
            guard operationToken == self.currentOperationToken else { return }
            guard self.activePlan != nil, self.pausedReason == nil else { return }

            let targetApp: NSRunningApplication? = {
                guard let hint = targetAppHint else { return nil }
                return AccessibilityTreeResolver().runningAppMatching(hint: hint)
            }()
            do {
                switch stepType {
                case .rightClick:
                    try await ActionExecutor.shared.rightClick(
                        atGlobalScreenPoint: resolution.globalScreenPoint,
                        activatingTargetApp: targetApp
                    )
                case .doubleClick:
                    try await ActionExecutor.shared.doubleClick(
                        atGlobalScreenPoint: resolution.globalScreenPoint,
                        activatingTargetApp: targetApp
                    )
                default:
                    try await ActionExecutor.shared.click(
                        atGlobalScreenPoint: resolution.globalScreenPoint,
                        activatingTargetApp: targetApp
                    )
                }
                guard operationToken == self.currentOperationToken else { return }
                guard self.activePlan != nil, self.pausedReason == nil else { return }
                self.advanceUsingCachedHandlers(isPostClick: true)
            } catch {
                print("[Workflow] autopilot click failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Non-Click Step Executors (Autopilot Only)

    private func executeOpenApplicationStep(
        step: WorkflowStep,
        operationToken: UUID
    ) async {
        guard isAutopilotEnabledProvider?() == true else {
            pause(.actionRequiresAutopilot(label: step.label ?? step.hint))
            return
        }
        let applicationName = step.label ?? activePlan?.app
        guard let applicationName, !applicationName.isEmpty else {
            print("[Workflow] openApp step has no application name — skipping")
            advanceUsingCachedHandlers(isPostClick: false)
            return
        }

        do {
            try await ActionExecutor.shared.openApplication(named: applicationName)
            guard operationToken == currentOperationToken else { return }
            advanceUsingCachedHandlers(isPostClick: true)
        } catch {
            print("[Workflow] open app \"\(applicationName)\" failed: \(error.localizedDescription)")
            currentStepResolutionFailureLabel = applicationName
        }
    }

    private func executeOpenURLStep(
        step: WorkflowStep,
        operationToken: UUID
    ) async {
        guard isAutopilotEnabledProvider?() == true else {
            pause(.actionRequiresAutopilot(label: step.label ?? step.hint))
            return
        }
        guard let rawURLString = step.label, !rawURLString.isEmpty else {
            print("[Workflow] openURL step has no URL — skipping")
            advanceUsingCachedHandlers(isPostClick: false)
            return
        }

        do {
            try await ActionExecutor.shared.openURL(
                rawURLString,
                preferredApplicationName: activePlan?.app
            )
            guard operationToken == currentOperationToken else { return }
            advanceUsingCachedHandlers(isPostClick: true)
        } catch {
            print("[Workflow] open URL \"\(rawURLString)\" failed: \(error.localizedDescription)")
            currentStepResolutionFailureLabel = rawURLString
        }
    }

    /// Execute a `.keyboardShortcut` step. The step's `label` is
    /// expected to be the shortcut string (e.g. "Cmd+S"). In Teaching
    /// mode the step pauses because Cuse can't point at a key combo.
    private func executeKeyboardShortcutStep(
        step: WorkflowStep,
        operationToken: UUID
    ) async {
        guard isAutopilotEnabledProvider?() == true else {
            pause(.actionRequiresAutopilot(label: step.label ?? step.hint))
            return
        }
        guard let shortcut = step.label, !shortcut.isEmpty else {
            print("[Workflow] keyboard shortcut step has no label — skipping")
            advanceUsingCachedHandlers(isPostClick: false)
            return
        }

        let targetApp: NSRunningApplication? = {
            guard let hint = activePlan?.app else { return nil }
            return AccessibilityTreeResolver().runningAppMatching(hint: hint)
        }()
        do {
            try await ActionExecutor.shared.pressKeyboardShortcut(
                shortcut,
                activatingTargetApp: targetApp
            )
            guard operationToken == currentOperationToken else { return }
            advanceUsingCachedHandlers(isPostClick: false)
        } catch {
            print("[Workflow] keyboard shortcut \"\(shortcut)\" failed: \(error.localizedDescription)")
            currentStepResolutionFailureLabel = shortcut
        }
    }

    private func executePressKeyStep(
        step: WorkflowStep,
        operationToken: UUID
    ) async {
        guard isAutopilotEnabledProvider?() == true else {
            pause(.actionRequiresAutopilot(label: step.label ?? step.hint))
            return
        }
        guard let keyName = step.label, !keyName.isEmpty else {
            print("[Workflow] pressKey step has no key — skipping")
            advanceUsingCachedHandlers(isPostClick: false)
            return
        }

        let targetApp = targetAppForActivePlan()
        do {
            try await ActionExecutor.shared.pressKey(
                keyName,
                activatingTargetApp: targetApp
            )
            guard operationToken == currentOperationToken else { return }
            advanceUsingCachedHandlers(isPostClick: false)
        } catch {
            print("[Workflow] press key \"\(keyName)\" failed: \(error.localizedDescription)")
            currentStepResolutionFailureLabel = keyName
        }
    }

    /// Execute a `.type` step into the currently focused field. Gemini
    /// may use `label` for the target name ("Note body") and `value`
    /// for the actual text; prefer `value` so labels are never inserted
    /// as content.
    private func executeTypeTextStep(
        step: WorkflowStep,
        operationToken: UUID
    ) async {
        guard isAutopilotEnabledProvider?() == true else {
            pause(.actionRequiresAutopilot(label: step.label ?? step.hint))
            return
        }
        let textToType = step.value ?? step.label
        guard let textToType, !textToType.isEmpty else {
            print("[Workflow] type step has no text — skipping")
            advanceUsingCachedHandlers(isPostClick: false)
            return
        }

        let targetApp: NSRunningApplication? = {
            guard let hint = activePlan?.app else { return nil }
            return AccessibilityTreeResolver().runningAppMatching(hint: hint)
        }()
        do {
            try await ActionExecutor.shared.typeText(
                textToType,
                activatingTargetApp: targetApp
            )
            guard operationToken == currentOperationToken else { return }
            advanceUsingCachedHandlers(isPostClick: false)
        } catch {
            print("[Workflow] type \"\(textToType.prefix(40))…\" failed: \(error.localizedDescription)")
            currentStepResolutionFailureLabel = "type"
        }
    }

    private func executeSetValueStep(
        step: WorkflowStep,
        operationToken: UUID
    ) async {
        guard isAutopilotEnabledProvider?() == true else {
            pause(.actionRequiresAutopilot(label: step.value ?? step.label ?? step.hint))
            return
        }
        let valueToSet = step.value ?? step.label
        guard let valueToSet, !valueToSet.isEmpty else {
            print("[Workflow] setValue step has no value — skipping")
            advanceUsingCachedHandlers(isPostClick: false)
            return
        }

        let targetApp = targetAppForActivePlan()
        do {
            try await ActionExecutor.shared.setFocusedValue(
                valueToSet,
                activatingTargetApp: targetApp
            )
            guard operationToken == currentOperationToken else { return }
            advanceUsingCachedHandlers(isPostClick: true)
        } catch {
            print("[Workflow] set value failed: \(error.localizedDescription)")
            currentStepResolutionFailureLabel = valueToSet
        }
    }

    private func executeScrollStep(
        step: WorkflowStep,
        operationToken: UUID
    ) async {
        guard isAutopilotEnabledProvider?() == true else {
            pause(.actionRequiresAutopilot(label: step.hint))
            return
        }
        let direction = step.direction ?? step.label ?? "down"
        let amount = step.amount ?? 3
        let granularity = step.by ?? "line"

        let targetApp = targetAppForActivePlan()
        do {
            try await ActionExecutor.shared.scroll(
                direction: direction,
                amount: amount,
                by: granularity,
                activatingTargetApp: targetApp
            )
            guard operationToken == currentOperationToken else { return }
            advanceUsingCachedHandlers(isPostClick: true)
        } catch {
            print("[Workflow] scroll \(direction) failed: \(error.localizedDescription)")
            currentStepResolutionFailureLabel = direction
        }
    }

    private func targetAppForActivePlan() -> NSRunningApplication? {
        guard let hint = activePlan?.app else { return nil }
        return AccessibilityTreeResolver().runningAppMatching(hint: hint)
    }

    // MARK: - App-Switch Pause

    /// Subscribe to NSWorkspace's "did activate application" notification.
    /// While a plan is active, switching to an unrelated app pauses the
    /// workflow so we don't drive the cursor in the wrong app. Activations
    /// of the *target* app are intentionally tolerated — many workflows
    /// involve focus toggling between menu bar / dock / popovers without
    /// being a real "user changed their mind."
    private func startObservingAppActivationsForCurrentPlan() {
        stopObservingAppActivations()
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Hop onto MainActor explicitly — NotificationCenter
            // handlers don't inherit actor isolation.
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.activePlan != nil, self.pausedReason == nil else { return }
                guard let activatedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bundleID = activatedApp.bundleIdentifier else { return }
                // Ignore activations of our own menu bar app — pressing
                // the hotkey momentarily makes us frontmost.
                if bundleID == Bundle.main.bundleIdentifier { return }
                // Tolerate activations of the plan's target app — that's
                // a legitimate part of nearly every workflow.
                if self.activationMatchesCurrentPlanTarget(activatedApp) {
                    return
                }
                self.pause(.userSwitchedToUnrelatedApp(bundleID: bundleID))
            }
        }
    }

    private func stopObservingAppActivations() {
        if let observer = appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appActivationObserver = nil
        }
    }

    private func activationMatchesCurrentPlanTarget(_ activatedApp: NSRunningApplication) -> Bool {
        if let bundleID = activatedApp.bundleIdentifier,
           let targetBundleID = planTargetAppBundleID,
           bundleID == targetBundleID {
            return true
        }

        let targetNames = [
            activePlan?.app,
            activeStep?.type == .openApp ? activeStep?.label : nil
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        let activatedAppName = activatedApp.localizedName?.lowercased()
        let activatedBundleID = activatedApp.bundleIdentifier?.lowercased()
        let matchesTargetName = targetNames.contains { targetName in
            activatedAppName == targetName
                || activatedAppName?.contains(targetName) == true
                || activatedBundleID?.contains(targetName) == true
        }

        if matchesTargetName {
            planTargetAppBundleID = activatedApp.bundleIdentifier
        }

        return matchesTargetName
    }

    // MARK: - Modal Dialog Detection

    /// Returns the title (or nil for "no title") of a sheet / dialog
    /// currently presented over the target app's main window. Returns
    /// nil if no such modal is detected.
    ///
    /// We match on AXSheet (the standard sheet role) AND on AXWindow with
    /// AXSubrole == AXDialog (older / non-sheet dialogs). Both block
    /// further interaction with the parent window's elements, so both
    /// should pause a workflow.
    private static func detectBlockingModalDialogTitle(targetAppHint: String) -> String? {
        guard AccessibilityTreeResolver.isPermissionGranted else { return nil }

        // Reuse the resolver's app-finding logic so we query the same
        // app the rest of the runner is targeting.
        let resolver = AccessibilityTreeResolver()
        guard let runningApp = resolver.runningAppMatching(hint: targetAppHint) else { return nil }
        let axApp = AXUIElementCreateApplication(runningApp.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.2)

        var windowsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return nil
        }

        for window in windows {
            // Sheets attached to the window. AX exposes sheets as
            // children of the window (role == "AXSheet"). Using string
            // literals for the role names instead of CoreFoundation
            // constants keeps this resilient across SDK versions where
            // the constant naming has changed.
            var sheetRef: AnyObject?
            if AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &sheetRef) == .success,
               let children = sheetRef as? [AXUIElement] {
                for child in children {
                    var roleRef: AnyObject?
                    if AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef) == .success,
                       let role = roleRef as? String,
                       role == "AXSheet" {
                        var titleRef: AnyObject?
                        AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef)
                        return (titleRef as? String) ?? ""
                    }
                }
            }

            // Standalone dialog windows — AX subrole "AXDialog" or
            // "AXSystemDialog". Both block parent-window interaction.
            var subroleRef: AnyObject?
            if AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleRef) == .success,
               let subrole = subroleRef as? String,
               subrole == "AXDialog" || subrole == "AXSystemDialog" {
                var titleRef: AnyObject?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
                return (titleRef as? String) ?? ""
            }
        }

        return nil
    }

    // MARK: - AX Fingerprint (Validator Backbone)

    /// Snapshot a deterministic fingerprint of the target app's AX
    /// state. The validator compares pre- and post-click fingerprints
    /// to decide whether the click did anything observable.
    ///
    /// The fingerprint is a hash of the focused-window's role/title/value
    /// triples for the first ~120 elements we encounter (BFS-truncated
    /// for cost). It changes when:
    ///   • The focused window changes
    ///   • A menu opens/closes
    ///   • A sheet appears
    ///   • The window's content updates enough to swap any of those
    ///     elements
    /// It does NOT change for cosmetic-only repaints (cursor moves,
    /// hover highlights) — exactly what we want.
    private static func captureAccessibilityFingerprint(targetAppHint: String?) -> String? {
        guard AccessibilityTreeResolver.isPermissionGranted else { return nil }
        guard let hint = targetAppHint else { return nil }

        let resolver = AccessibilityTreeResolver()
        guard let runningApp = resolver.runningAppMatching(hint: hint) else { return nil }
        let axApp = AXUIElementCreateApplication(runningApp.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.2)

        // Walk the focused window only — much cheaper than the whole app
        // tree, and it's the part that matters for "did anything change".
        var focusedWindowRef: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindowRef) == .success,
              let focusedWindow = focusedWindowRef else {
            return nil
        }
        let root = focusedWindow as! AXUIElement

        var triples: [String] = []
        let maxNodesToHash = 120
        let deadline = Date().addingTimeInterval(0.15)

        func walk(_ node: AXUIElement, depth: Int) {
            guard triples.count < maxNodesToHash, depth < 8, Date() < deadline else { return }

            var roleRef: AnyObject?
            var titleRef: AnyObject?
            var valueRef: AnyObject?
            AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &roleRef)
            AXUIElementCopyAttributeValue(node, kAXTitleAttribute as CFString, &titleRef)
            AXUIElementCopyAttributeValue(node, kAXValueAttribute as CFString, &valueRef)

            let role = (roleRef as? String) ?? ""
            let title = (titleRef as? String) ?? ""
            // Stringify primitive value types only — coerced AX values
            // (like AXValueRef ranges) aren't reliably hashable.
            let value: String = {
                if let s = valueRef as? String { return s }
                if let n = valueRef as? NSNumber { return n.stringValue }
                return ""
            }()
            // Truncate long values so a multi-megabyte text editor body
            // doesn't dominate the fingerprint cost.
            let truncatedValue = value.count > 120 ? String(value.prefix(120)) : value
            triples.append("\(role)|\(title)|\(truncatedValue)")

            var childrenRef: AnyObject?
            if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                for child in children {
                    if triples.count >= maxNodesToHash { return }
                    walk(child, depth: depth + 1)
                }
            }
        }

        walk(root, depth: 0)

        // SHA256-style stable hashing without pulling in CryptoKit:
        // joining triples and hashing the joined string as UInt64 is
        // good enough for change-detection. Collisions don't matter
        // here — a false negative (hash matches but state actually
        // changed) just causes an unnecessary pause, never a wrong
        // advance.
        let joined = triples.joined(separator: "\n")
        return String(joined.hashValue)
    }

    private func shouldSkipAccessibilityResolution(for appHint: String?) -> Bool {
        if Self.shouldTreatAsRawVisionOnlyApp(appHint) {
            return true
        }
        return AccessibilityTreeResolver.isAppKnownToLackAXTree(hint: appHint)
    }

    private static func shouldTreatAsRawVisionOnlyApp(_ appHint: String?) -> Bool {
        guard let normalizedAppHint = appHint?.lowercased() else { return false }
        return normalizedAppHint.contains("blender")
            || normalizedAppHint.contains("org.blenderfoundation.blender")
    }

    // MARK: - Helpers

    /// Best-effort mapping from a human-readable app name to a bundle
    /// ID for the activation observer. Returns nil if no running app
    /// matches — in which case we won't be able to detect the
    /// "switched to unrelated app" pause condition for this plan.
    private static func bundleIDForAppName(_ name: String?) -> String? {
        guard let name = name, !name.isEmpty else { return nil }
        let needle = name.lowercased()
        for app in NSWorkspace.shared.runningApplications {
            if let localized = app.localizedName?.lowercased(), localized == needle || localized.contains(needle) {
                return app.bundleIdentifier
            }
            if let bundleID = app.bundleIdentifier?.lowercased(), bundleID.contains(needle) {
                return app.bundleIdentifier
            }
        }
        return nil
    }

    private func recordWorkflowEvent(
        name: String,
        status: String,
        message: String? = nil,
        metadata: [String: String] = [:]
    ) {
        PipelineLogStore.shared.record(
            category: "workflow",
            name: name,
            status: status,
            message: message,
            metadata: metadata
        )
    }

    private func activeWorkflowMetadata() -> [String: String] {
        var metadata: [String: String] = [
            "active_step_index": String(activeStepIndex + 1),
            "paused": String(pausedReason != nil),
            "resolving": String(isResolvingCurrentStep)
        ]
        if let activePlan {
            metadata.merge(workflowPlanMetadata(activePlan), uniquingKeysWith: { existing, _ in existing })
        }
        if let activeStep {
            metadata.merge(workflowStepMetadata(activeStep), uniquingKeysWith: { existing, _ in existing })
        }
        if let currentOperationToken {
            metadata["operation_token"] = String(currentOperationToken.uuidString.prefix(8))
        }
        return metadata
    }

    private func workflowPlanMetadata(_ plan: WorkflowPlan) -> [String: String] {
        var metadata = [
            "goal": plan.goal,
            "app": plan.app ?? "unknown",
            "step_count": String(plan.steps.count)
        ]
        if let traceID = plan.traceID {
            metadata[CuseActionTrace.metadataKey] = traceID
        }
        return metadata
    }

    private func workflowStepMetadata(_ step: WorkflowStep) -> [String: String] {
        var metadata: [String: String] = [
            "step_id": step.id,
            "action_type": step.type.rawValue,
            "label": step.label ?? "none",
            "value_preview": step.value.map { String($0.prefix(80)) } ?? "none",
            "target_id": step.targetID ?? "none",
            "target_mark": step.targetMark.map(String.init) ?? "none",
            "hint": step.hint
        ]
        if let box = step.box2DNormalized {
            metadata["box_2d"] = box.map(String.init).joined(separator: ",")
        }
        if let hintCoordinate = step.hintCoordinate {
            metadata["hint_pixel"] = [
                String(format: "%.1f", hintCoordinate.x),
                String(format: "%.1f", hintCoordinate.y)
            ].joined(separator: ",")
        }
        return metadata
    }

    private func canvasVisualObjectTextMatchRejectionReason(
        resolution: ElementResolver.Resolution,
        step: WorkflowStep?,
        plan: WorkflowPlan?
    ) -> String? {
        guard let step,
              step.type == .observe,
              isCanvasLikeApp(plan?.app) else {
            return nil
        }

        switch resolution.source {
        case .localPerceptionCache, .nativeDetectorCache:
            break
        default:
            return nil
        }

        let contextText = [
            plan?.goal,
            step.label,
            step.hint
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        guard mentionsCanvasVisualObject(contextText),
              !mentionsMenuOrControlContext(contextText) else {
            return nil
        }

        guard let rect = resolution.globalScreenRect else {
            return (step.hintCoordinate != nil || step.box2DNormalized != nil)
                ? "canvas_visual_object_prefers_llm_coordinates"
                : "canvas_visual_object_needs_point_2d_or_box_2d"
        }

        let width = abs(rect.width)
        let height = abs(rect.height)
        let aspectRatio = width / max(height, 1)
        let looksLikeTextOrMenuLabel = height <= 80 && aspectRatio >= 3.5
        guard looksLikeTextOrMenuLabel else {
            return nil
        }

        return (step.hintCoordinate != nil || step.box2DNormalized != nil)
            ? "canvas_visual_object_prefers_llm_coordinates"
            : "canvas_visual_object_needs_point_2d_or_box_2d"
    }

    private func isCanvasLikeApp(_ appName: String?) -> Bool {
        guard let appName = appName?.lowercased() else { return false }
        return appName.contains("blender")
            || appName.contains("figma")
            || appName.contains("photoshop")
            || appName.contains("illustrator")
            || appName.contains("unity")
            || appName.contains("unreal")
    }

    private func mentionsCanvasVisualObject(_ text: String) -> Bool {
        let visualObjectTerms = [
            "3d",
            "canvas",
            "cone",
            "cube",
            "cylinder",
            "geometry",
            "house",
            "mesh",
            "model",
            "object",
            "shape",
            "sphere",
            "torus"
        ]
        return visualObjectTerms.contains { text.contains($0) }
    }

    private func mentionsMenuOrControlContext(_ text: String) -> Bool {
        let controlTerms = [
            "button",
            "control",
            "field",
            "item",
            "menu",
            "option",
            "panel",
            "submenu",
            "tab",
            "toolbar"
        ]
        return controlTerms.contains { text.contains($0) }
    }

    private func resolutionMetadata(_ resolution: ElementResolver.Resolution) -> [String: String] {
        var metadata: [String: String] = [
            "resolved_label": resolution.label,
            "resolution_source": resolutionSourceName(resolution.source),
            "resolved_x": String(format: "%.1f", resolution.globalScreenPoint.x),
            "resolved_y": String(format: "%.1f", resolution.globalScreenPoint.y),
            "display_frame": [
                resolution.displayFrame.minX,
                resolution.displayFrame.minY,
                resolution.displayFrame.maxX,
                resolution.displayFrame.maxY
            ].map { String(format: "%.1f", $0) }.joined(separator: ",")
        ]
        if let rect = resolution.globalScreenRect {
            metadata["resolved_rect"] = [
                rect.minX,
                rect.minY,
                rect.maxX,
                rect.maxY
            ].map { String(format: "%.1f", $0) }.joined(separator: ",")
        }
        return metadata
    }

    private func resolutionSourceName(_ source: ElementResolver.ResolutionSource) -> String {
        switch source {
        case .accessibilityTree:
            return "accessibility_tree"
        case .browserDOMCoordinates:
            return "browser_dom"
        case .nativeDetectorCache:
            return "native_detector"
        case .localPerceptionCache:
            return "local_perception"
        case .llmRawCoordinates:
            return "llm_raw_coordinates"
        }
    }

    /// Grab a capture of every connected display. Returns an empty array
    /// on failure — the caller decides how to fall back.
    private static func captureAllScreens() async -> [CompanionScreenCapture] {
        do {
            return try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
        } catch {
            print("[Workflow] failed to capture screens: \(error)")
            return []
        }
    }
}
