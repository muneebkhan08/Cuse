//
//  CuseAgentContract.swift
//  Cuse
//
//  Canonical contract for external agents using Cuse as the local
//  perception, grounding, action, and validation harness.
//

import Foundation

struct CuseAgentContractSnapshot: Encodable {
    let ok: Bool
    let version: String
    let baseURL: String
    let summary: String
    let canonicalLoop: [String]
    let normalEndpoints: [String]
    let debugEndpoints: [String]
    let rules: [String]
}

enum CuseAgentContract {
    static let version = "2026-09-19"
    static let baseURL = "http://127.0.0.1:19474"

    static let snapshot = CuseAgentContractSnapshot(
        ok: true,
        version: version,
        baseURL: baseURL,
        summary: "Cuse is the local macOS visual context broker, perception target grounder, pointer/action executor, and post-action validator. External agents do long-horizon reasoning, web/files/tool orchestration, and asset handling; Cuse executes one desktop action at a time.",
        canonicalLoop: [
            "GET /v1/observe to confirm app, toggles, and current state.",
            "Preserve one trace_id across the whole user task and include it in every harness request body.",
            "Use the agent's own web, browser, terminal, file, memory, and skill tools for research, downloads, file staging, and planning; call Cuse only when the local Mac needs observation, grounding, GUI action, or visual verification.",
            "When the user refers to a highlighted file, image, text, URL, or 'this thing', POST /v1/resolve-highlight-source first so Cuse can return the source and valid tool suggestions.",
            "POST /v1/visual-context with visual_context=\"auto\" before uncertain, canvas, task-start, failed, or visually rich steps; include query or target_label when the question is about a specific target so Cuse can prefer target_crop.",
            "For visible UI controls, POST /v1/ground-target for the next target only, then POST /v1/act with the returned targetID or targetMark.",
            "For targetless keyboard, typing, app, URL, or coordinate-bearing canvas steps, POST /v1/workflow-plan with exactly one step.",
            "When you already have a deterministic mini-sequence, such as Blender modal transform S, Z, type value, Return, POST /v1/tasks instead of sending multiple steps to /v1/workflow-plan.",
            "Read the compact action response. If unclear, GET /v1/action-history and filter logs by trace_id.",
            "Repeat from observe or visual-context. Never ask Cuse to plan the whole task."
        ],
        normalEndpoints: [
            "GET /v1/observe",
            "POST /v1/visual-context",
            "POST /v1/resolve-highlight-source",
            "POST /v1/ground-target",
            "POST /v1/act",
            "POST /v1/workflow-plan",
            "POST /v1/tasks",
            "GET /v1/tasks/{task_id}",
            "GET /v1/tasks/{task_id}/events",
            "GET /v1/action-history",
            "GET /v1/skills/active"
        ],
        debugEndpoints: [
            "POST /v1/text-command",
            "GET /v1/text-command",
            "GET /v1/targets",
            "GET /v1/screenshots"
        ],
        rules: [
            "One action per request. Wait for completion, pause, failure, or validation before deciding the next action.",
            "Never send multiple steps to /v1/workflow-plan. Use /v1/tasks only for a concrete deterministic mini-sequence, not for open-ended planning.",
            "Use /v1/visual-context instead of /v1/screenshots in normal loops. Raw screenshots are for explicit debugging.",
            "Use /v1/ground-target instead of full /v1/targets in normal loops.",
            "Use exact targetID or targetMark once Cuse returns one.",
            "For Blender/canvas viewport objects, include point_2d or box_2d; bare labels can match outliner/menu/property text instead of the object.",
            "Do not ask Cuse to browse the web, choose downloads, inspect licenses, or transform local files. Use the agent's own tools for those parts, then hand Cuse the local UI/action step if needed.",
            "For Blender asset import, prefer reliable local file import through Blender scripting/terminal tools when available; use Cuse to drive File/Open/Import UI when the user specifically wants visible UI interaction or scripting is unavailable.",
            "Do not click password, 2FA, payment, consent, or credential-finalization controls automatically.",
            "Keep user-facing narration short and do not claim success until Cuse returns success or a useful observation."
        ]
    )

}
