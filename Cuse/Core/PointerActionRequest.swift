//
//  PointerActionRequest.swift
//  Cuse
//
//  Shared one-action request shape for voice, text, and harness callers.
//

import Foundation

struct PointerActionRequest {
    let goal: String
    let app: String?
    let actionType: WorkflowStep.StepType
    let targetLabel: String?
    let targetID: String?
    let targetMark: Int?
    let execute: Bool
    let allowScreenshotPlanning: Bool
    let validateStateChange: Bool
    let traceID: String?

    init(
        goal: String,
        app: String?,
        actionType: WorkflowStep.StepType,
        targetLabel: String?,
        targetID: String?,
        targetMark: Int?,
        execute: Bool,
        allowScreenshotPlanning: Bool,
        validateStateChange: Bool,
        traceID: String? = nil
    ) {
        self.goal = goal
        self.app = app
        self.actionType = actionType
        self.targetLabel = targetLabel
        self.targetID = targetID
        self.targetMark = targetMark
        self.execute = execute
        self.allowScreenshotPlanning = allowScreenshotPlanning
        self.validateStateChange = validateStateChange
        self.traceID = traceID
    }

    func withTraceID(_ traceID: String) -> PointerActionRequest {
        PointerActionRequest(
            goal: goal,
            app: app,
            actionType: actionType,
            targetLabel: targetLabel,
            targetID: targetID,
            targetMark: targetMark,
            execute: execute,
            allowScreenshotPlanning: allowScreenshotPlanning,
            validateStateChange: validateStateChange,
            traceID: traceID
        )
    }
}
