//
//  WorkflowPlan.swift
//  Cuse
//
//  Schema for AI-generated single-action workflows. Gemini emits a//  structured action request (JSON); Cuse resolves and executes one//  step, then waits
//
//  The `steps` array is kept for
//
import Foundation
import CoreGraphics

/// A single action in a workflow. Most steps today are `click` with a
/// label; the enum is extensible so we can add `type`, `scroll`,
/// `wait_for_state`, `keyboard_shortcut`, etc. without breaking the
/// schema.
struct WorkflowStep: Codable, Identifiable, Hashable {
    /// Stable id for referring to this step in workflow state.
    /// Generated from the step index at parse time if the LLM doesn't
    /// provide one.
    let id: String

    /// What kind of action this step represents.
    /// Clicks, keyboard shortcuts, typing, app launch, URL launch, and
    /// scrolling all execute as a single accepted action.
    let type: StepType

    /// Human-readable label for the element, e.g. "File", "New",
    /// "General template". Passed to ElementResolver for pixel lookup.
    let label: String?
    /// Exact local target chosen from LocalPerceptionTargetCache. This is
    /// preferred over fuzzy label matching when a planner selects a mark.
    let targetID: String?
    let targetMark: Int?
    let value: String?
    let direction: String?
    let amount: Int?
    let by: String?
    let targetContext: TargetContext?

    /// Short sentence describing what the user should do at this step.
    /// Used for the on-screen step list UI (e.g. "Click the File menu").
    let hint: String

    /// Optional hint coordinate from the LLM (Gemini's box_2d center
    /// in screenshot pixel space). Used by ElementResolver as the
    /// fallback when the AX tree has no match for the label.
    let hintX: Int?
    let hintY: Int?
    /// Original Gemini box_2d in normalized [y1, x1, y2, x2] space.
    /// Keeping this lets us scale against the exact screenshot capture
    /// used for a resolution attempt instead of reusing stale pixels.
    let box2DNormalized: [Int]?

    /// Which screen the action happens on (for multi-monitor). nil =
    /// use the cursor's current screen.
    let screenNumber: Int?

    enum StepType: String, Codable, Hashable {
        case click            // point at and click an element
        case rightClick       // point at and right-click an element
        case doubleClick      // point at and double-click an element
        case openApp          // launch or foreground an application
        case openURL          // open a URL or file/folder URL
        case keyboardShortcut // press a specific key combo (e.g. "Cmd+N")
        case pressKey         // press one key (e.g. Return, Escape, PageDown)
        case type             // type text into a focused field
        case setValue         // set AXValue on the focused element
        case scroll           // scroll in a specific direction
        case waitForState     // pause until a condition is visually satisfied
        case observe          // nothing to do — just highlight for the user

        static func normalized(from rawTypeName: String?) -> StepType {
            let compactTypeName = (rawTypeName ?? "click")
                .lowercased()
                .filter { $0.isLetter || $0.isNumber }

            switch compactTypeName {
            case "openapp", "launchapp", "launchapplication", "openapplication":
                return .openApp
            case "openurl", "url", "openlink", "openwebsite", "openfile", "openfolder":
                return .openURL
            case "rightclick", "secondaryclick", "contextclick":
                return .rightClick
            case "doubleclick":
                return .doubleClick
            case "keyboardshortcut", "hotkey", "shortcut":
                return .keyboardShortcut
            case "presskey", "key":
                return .pressKey
            case "typetext", "inputtext", "entertext":
                return .type
            case "setvalue", "set":
                return .setValue
            case "waitforstate", "wait":
                return .waitForState
            default:
                return StepType(rawValue: compactTypeName) ?? .click
            }
        }
    }

    enum TargetContext: String, Codable, Hashable {
        case visibleElement
        case currentHighlight
        case currentSelection
        case focusedElement

        static func normalized(from rawTargetContext: String?) -> TargetContext? {
            guard let rawTargetContext else { return nil }
            let compactTargetContext = rawTargetContext
                .lowercased()
                .filter { $0.isLetter || $0.isNumber }

            switch compactTargetContext {
            case "highlight", "currenthighlight", "focusedhighlight", "paintedhighlight":
                return .currentHighlight
            case "selection", "currentselection", "selectedtext", "textselection":
                return .currentSelection
            case "focus", "focused", "focusedelement", "activefield":
                return .focusedElement
            case "visible", "visibleelement", "screen", "onscreen":
                return .visibleElement
            default:
                return nil
            }
        }
    }

    /// Convenience — the LLM's coordinate hint as a CGPoint if both
    /// components are present.
    var hintCoordinate: CGPoint? {
        guard let hintX, let hintY else { return nil }
        return CGPoint(x: hintX, y: hintY)
    }

    func hintCoordinate(in capture: CompanionScreenCapture?) -> CGPoint? {
        if let hintCoordinate {
            return hintCoordinate
        }

        guard let box = box2DNormalized, box.count == 4, let capture else {
            return nil
        }

        let y1Norm = CGFloat(box[0])
        let x1Norm = CGFloat(box[1])
        let y2Norm = CGFloat(box[2])
        let x2Norm = CGFloat(box[3])

        let centerNormX = (x1Norm + x2Norm) / 2
        let centerNormY = (y1Norm + y2Norm) / 2

        let pixelX = centerNormX * CGFloat(capture.screenshotWidthInPixels) / 1000
        let pixelY = centerNormY * CGFloat(capture.screenshotHeightInPixels) / 1000
        return CGPoint(x: pixelX, y: pixelY)
    }
}

/// A complete workflow — one user question's answer expressed as an
/// ordered sequence of steps.
struct WorkflowPlan: Codable, Hashable {
    /// High-level description of what the workflow achieves.
    /// Shown as the title of the step-list UI.
    let goal: String

    /// The app this workflow targets. Used for app-switching and
    /// deciding whether the plan is still applicable when the user
    /// changes focus.
    let app: String?

    /// Ordered list of steps. The app executes them one at a time.
    let steps: [WorkflowStep]

    /// Stable id for following one user/action request through planner,
    /// grounding, execution, validation, and logs.
    let traceID: String?

    /// True when the caller said this click need not change the screen, such
    /// as Laya focusing a text field before typing in a separate plan. The
    /// runner then skips its "click didn't register" pause, which otherwise
    /// only knows to skip when the typing step is in the same plan.
    /// Optional so plans decoded from harness JSON without it still work.
    let skipsPostClickStateCheck: Bool?

    init(
        goal: String,
        app: String?,
        steps: [WorkflowStep],
        traceID: String? = nil,
        skipsPostClickStateCheck: Bool? = nil
    ) {
        self.goal = goal
        self.app = app
        self.steps = steps
        self.traceID = traceID
        self.skipsPostClickStateCheck = skipsPostClickStateCheck
    }

    func withTraceID(_ traceID: String) -> WorkflowPlan {
        WorkflowPlan(
            goal: goal,
            app: app,
            steps: steps,
            traceID: traceID,
            skipsPostClickStateCheck: skipsPostClickStateCheck
        )
    }
}

enum CuseActionTrace {
    static let metadataKey = "trace_id"

    static func makeID(source: String) -> String {
        let normalizedSource = source
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        let prefix = normalizedSource.isEmpty ? "action" : String(normalizedSource.prefix(10))
        return "\(prefix)_\(UUID().uuidString.prefix(8))"
    }
}

// MARK: - Parsing

extension WorkflowPlan {

    /// Parse a workflow plan from a JSON string. Accepts either a
    /// fenced `json ...` code block (typical LLM response) or a raw
    /// JSON object. Returns nil if the input isn't a valid plan.
    ///
    /// This is deliberately tolerant — LLMs sometimes emit extra
    /// whitespace, leading prose, or trailing explanations. We extract
    /// the first `{ ... }` JSON object we find and try to parse that.
    static func parse(from text: String) -> WorkflowPlan? {
        guard let jsonSubstring = extractFirstJSONObject(from: text) else { return nil }
        guard let data = jsonSubstring.data(using: .utf8) else { return nil }

        let decoder = JSONDecoder()
        if let plan = try? decoder.decode(WorkflowPlan.self, from: data) {
            return plan
        }

        // Fallback: the LLM might have given us a raw array of steps
        // wrapped in a schema-less object. Try to handle common variants.
        if let flexibleSteps = try? decoder.decode(FlexiblePlanPayload.self, from: data) {
            return flexibleSteps.toPlan()
        }

        return nil
    }

    /// Scan the string for the first balanced `{ ... }` JSON object.
    /// Handles nested braces correctly.
    private static func extractFirstJSONObject(from text: String) -> String? {
        var depth = 0
        var startIndex: String.Index?
        for i in text.indices {
            let ch = text[i]
            if ch == "{" {
                if depth == 0 { startIndex = i }
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0, let start = startIndex {
                    return String(text[start...i])
                }
            }
        }
        return nil
    }
}

// MARK: - Flexible Payload (tolerates minor schema drift)

/// Used as a fallback when the LLM's JSON doesn't exactly match our
/// strict schema. Accepts common variations in key names and makes
/// a best-effort conversion to a WorkflowPlan.
private struct FlexiblePlanPayload: Codable {
    let goal: String?
    let title: String?
    let app: String?
    let traceID: String?
    let trace_id: String?
    let steps: [FlexibleStep]?
    let plan: [FlexibleStep]?

    struct FlexibleStep: Codable {
        let id: String?
        let type: String?
        let action: String?
        let label: String?
        let target: String?
        let element: String?
        let targetLabel: String?
        let target_label: String?
        let targetID: String?
        let target_id: String?
        let targetMark: Int?
        let target_mark: Int?
        let key: String?
        let shortcut: String?
        let hint: String?
        let description: String?
        let x: Int?
        let y: Int?
        let screenNumber: Int?
        let screen: Int?
        let value: String?
        let text: String?
        let direction: String?
        let amount: Int?
        let by: String?
        let targetContext: String?
        let target_context: String?
    }

    func toPlan() -> WorkflowPlan? {
        let rawSteps = steps ?? plan ?? []
        guard !rawSteps.isEmpty else { return nil }

        let normalizedSteps: [WorkflowStep] = rawSteps.enumerated().map { index, s in
            return WorkflowStep(
                id: s.id ?? "step_\(index + 1)",
                type: WorkflowStep.StepType.normalized(from: s.type ?? s.action),
                label: s.label ?? s.target ?? s.element ?? s.targetLabel ?? s.target_label ?? s.key ?? s.shortcut,
                targetID: s.targetID ?? s.target_id,
                targetMark: s.targetMark ?? s.target_mark,
                value: s.value ?? s.text,
                direction: s.direction,
                amount: s.amount,
                by: s.by,
                targetContext: WorkflowStep.TargetContext.normalized(
                    from: s.targetContext ?? s.target_context
                ),
                hint: s.hint ?? s.description ?? "",
                hintX: s.x,
                hintY: s.y,
                box2DNormalized: nil,
                screenNumber: s.screenNumber ?? s.screen
            )
        }

        return WorkflowPlan(
            goal: goal ?? title ?? "Workflow",
            app: app,
            steps: normalizedSteps,
            traceID: traceID ?? trace_id
        )
    }
}
