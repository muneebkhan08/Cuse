//  GeminiFlashPlanner.swift
//  Combined mode's planner: Gemini Flash reads the task plus the locally
//  detected CoreML/OCR/AX labels and decides the next single step.
//
//  Gemini decides WHAT to do next and describes the target in words. It never
//  returns coordinates: Laya matches the description to a real detected box and
//  the shared engine moves the cursor. Request building and response parsing are
//  pure so they can be tested without a network or the app.

import Foundation

// MARK: - Elements

/// One locally detected element as the planner sees it.
nonisolated struct CombinedPlannerElement: Equatable {
    let id: String
    let label: String
    let source: String          // "ocr" | "yolo" | "ax"
    /// [ymin, xmin, ymax, xmax] scaled 0–1000 on the detection screenshot,
    /// the same convention Gemini uses for its own box_2d output.
    let normalizedBox2D: [Int]
}

// MARK: - Decision

nonisolated struct CombinedPlannerDecision: Equatable {
    enum Status: String {
        /// Perform `action` now.
        case act
        /// The task is already finished on screen.
        case done
        /// The labels alone are not enough; retry this step with a screenshot.
        case needScreenshot = "need_screenshot"
        /// Nothing on screen can move the task forward.
        case impossible
    }

    enum Action: String, CaseIterable {
        case click
        case doubleClick = "double_click"
        case rightClick = "right_click"
        case type
        case pressKey = "press_key"
        case keyboardShortcut = "keyboard_shortcut"
        case openApp = "open_app"

        /// Pointer actions need Laya to pick a detected box. The rest act on
        /// whatever is focused, so no target is chosen for them.
        var needsScreenTarget: Bool {
            self == .click || self == .doubleClick || self == .rightClick
        }
    }

    let status: Status
    /// Short remaining plan, first entry is the step being taken now. Shown in the panel.
    let remainingPlan: [String]
    let action: Action?
    /// Gemini's own pick from the element list, or nil when it named none.
    let targetID: String?
    /// Plain-words description of the control for Laya to match, e.g. "the New Folder button in the toolbar".
    let targetDescription: String
    /// Text to type, key to press ("Return"), shortcut ("Cmd+N"), or app name.
    let text: String
    let message: String
}

// MARK: - Errors

nonisolated enum GeminiFlashPlannerError: LocalizedError {
    case missingAPIKey
    case http(status: Int, body: String)
    case malformed(String)

    /// Google answers an invalid key with 401/403, or 400 carrying API_KEY_INVALID.
    static func isRejectedAPIKey(status: Int, body: String) -> Bool {
        status == 401 || status == 403 || (status == 400 && body.contains("API_KEY_INVALID"))
    }

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Combined mode needs your Gemini key. Paste it in Settings → Models. A key saved by an older Cuse build must be pasted once more."
        case let .http(status, body):
            if Self.isRejectedAPIKey(status: status, body: body) {
                return "Gemini rejected the saved API key. Paste a valid key from Google AI Studio in Settings → Models."
            }
            return "Gemini Flash returned \(status): \(body.prefix(300))"
        case let .malformed(detail):
            return "Gemini Flash sent an unreadable plan: \(detail)"
        }
    }
}

// MARK: - Request and response (pure)

nonisolated enum GeminiFlashPlanning {
    /// Tried in order. gemini-3.8-flash is the newest Flash listed for the key
    /// but has returned 503 (overloaded); gemini-3.7-flash answers this JSON
    /// schema with thinkingLevel low and was verified end to end in Calculator.
    static let modelIDs = ["gemini-3.8-flash", "gemini-3.7-flash"]

    /// Overloaded, rate-limited, unavailable or unknown-model responses move on
    /// to the next model. Other errors (bad key, bad request) are real failures.
    static func shouldTryNextModel(afterHTTPStatus httpStatus: Int) -> Bool {
        [404, 429, 500, 502, 503, 504].contains(httpStatus)
    }

    /// Keep prompts small so each planning call stays fast.
    static let maxElements = 200

    static let systemInstruction = """
    You plan macOS desktop tasks one step at a time for Cuse.
    You receive the user's task, the actions already completed, the frontmost app, and a list of \
    elements detected on screen by local CoreML, OCR and Accessibility. Each element has an id, a label, \
    a source and a box [ymin, xmin, ymax, xmax] scaled 0-1000 on the screen image.
    A separate local model called Laya matches your target_description to a detected element and moves \
    the cursor, so describe the target precisely: its visible text, its kind (button, menu item, field, tab, icon) \
    and where it is when similar labels exist.
    Rules:
    - Return exactly ONE next action. Never return coordinates.
    - For click, double_click and right_click, set target_id to the id of the element you mean when it is in the list.
    - To enter text, first click the field in one step, then use "type" in the next step.
    - press_key text is one key such as Return, Escape, Tab, Down. keyboard_shortcut text looks like Cmd+N.
    - open_app text is the application name.
    - Use status "done" only when the screen shows the task is complete.
    - Use status "need_screenshot" when the labels are not enough to identify the next control \
    (for example icon-only buttons with no text) and no screenshot is attached.
    - Use status "impossible" when nothing visible or reachable can advance the task.
    - remaining_plan is a very short list of the steps left, starting with this one.
    """

    /// Gemini's OpenAPI-style schema, so the reply is always one JSON object.
    static var responseSchema: [String: Any] {
        [
            "type": "OBJECT",
            "properties": [
                "status": ["type": "STRING", "enum": ["act", "done", "need_screenshot", "impossible"]],
                "remaining_plan": ["type": "ARRAY", "items": ["type": "STRING"]],
                "action": ["type": "STRING", "enum": CombinedPlannerDecision.Action.allCases.map(\.rawValue)],
                "target_id": ["type": "STRING"],
                "target_description": ["type": "STRING"],
                "text": ["type": "STRING"],
                "message": ["type": "STRING"]
            ],
            "required": ["status", "remaining_plan", "message"],
            "propertyOrdering": ["status", "remaining_plan", "action", "target_id", "target_description", "text", "message"]
        ]
    }

    /// Build one generateContent body.
    /// `reviewNote` is set when Laya and Gemini picked different elements, so Gemini looks again.
    static func requestBody(
        task: String,
        history: [String],
        appName: String?,
        elements: [CombinedPlannerElement],
        screenshotJPEGBase64: String?,
        reviewNote: String?
    ) throws -> [String: Any] {
        let elementList = elements.prefix(maxElements).map { element -> [String: Any] in
            [
                "id": element.id,
                "label": element.label.isEmpty ? "unlabeled element" : element.label,
                "source": element.source,
                "box": element.normalizedBox2D
            ]
        }
        var context: [String: Any] = [
            "task": task,
            "frontmost_app": appName ?? "unknown",
            "already_done": history.isEmpty ? ["nothing yet"] : history,
            "screenshot_attached": screenshotJPEGBase64 != nil,
            "elements": elementList
        ]
        if let reviewNote { context["review"] = reviewNote }

        let contextData = try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys])
        guard let contextText = String(data: contextData, encoding: .utf8) else {
            throw GeminiFlashPlannerError.malformed("could not encode the screen context")
        }

        var parts: [[String: Any]] = [["text": contextText]]
        if let screenshotJPEGBase64 {
            parts.append(["inlineData": ["mimeType": "image/jpeg", "data": screenshotJPEGBase64]])
        }

        return [
            "systemInstruction": ["parts": [["text": systemInstruction]]],
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": responseSchema,
                // Low thinking keeps each step fast while still reasoning about the layout.
                "thinkingConfig": ["thinkingLevel": "low"]
            ]
        ]
    }

    /// Pull the JSON answer out of a generateContent response. Thought parts are skipped.
    static func answerText(fromResponseData responseData: Data) throws -> (text: String, inputTokens: Int) {
        guard let root = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw GeminiFlashPlannerError.malformed("response is not a JSON object")
        }
        let inputTokens = ((root["usageMetadata"] as? [String: Any])?["promptTokenCount"] as? Int) ?? 0
        guard let candidates = root["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            let blockReason = (root["promptFeedback"] as? [String: Any])?["blockReason"] as? String
            throw GeminiFlashPlannerError.malformed(blockReason.map { "blocked: \($0)" } ?? "no candidates")
        }
        let answerText = parts
            .filter { ($0["thought"] as? Bool) != true }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !answerText.isEmpty else {
            throw GeminiFlashPlannerError.malformed("empty answer")
        }
        return (answerText, inputTokens)
    }

    /// Validate Gemini's JSON into a decision. Any id not in `elements` is dropped
    /// rather than trusted, so a decision can only ever name something real.
    static func decision(
        fromAnswerText answerText: String,
        elements: [CombinedPlannerElement]
    ) throws -> CombinedPlannerDecision {
        guard let answerData = answerText.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: answerData) as? [String: Any],
              let statusText = object["status"] as? String,
              let status = CombinedPlannerDecision.Status(rawValue: statusText) else {
            throw GeminiFlashPlannerError.malformed("missing or unknown status")
        }

        func trimmedString(_ key: String) -> String {
            ((object[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let remainingPlan = ((object["remaining_plan"] as? [String]) ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let knownElementIDs = Set(elements.map(\.id))
        let proposedTargetID = trimmedString("target_id")
        let targetID = knownElementIDs.contains(proposedTargetID) ? proposedTargetID : nil
        let targetDescription = trimmedString("target_description")
        let text = trimmedString("text")
        let message = trimmedString("message")

        var action: CombinedPlannerDecision.Action?
        if status == .act {
            guard let parsedAction = CombinedPlannerDecision.Action(rawValue: trimmedString("action")) else {
                throw GeminiFlashPlannerError.malformed("act without a known action")
            }
            if parsedAction.needsScreenTarget {
                guard !targetDescription.isEmpty || targetID != nil else {
                    throw GeminiFlashPlannerError.malformed("\(parsedAction.rawValue) without a target")
                }
            } else {
                guard !text.isEmpty else {
                    throw GeminiFlashPlannerError.malformed("\(parsedAction.rawValue) without text")
                }
            }
            action = parsedAction
        }

        return CombinedPlannerDecision(
            status: status,
            remainingPlan: remainingPlan,
            action: action,
            targetID: targetID,
            targetDescription: targetDescription,
            text: text,
            message: message
        )
    }
}

// MARK: - Client

actor GeminiFlashPlanner {
    static let shared = GeminiFlashPlanner()

    private static func endpoint(forModelID modelID: String) -> URL {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelID):generateContent")!
    }

    /// Index into `GeminiFlashPlanning.modelIDs` of the model to try first.
    /// Once a model is overloaded the planner stays on the fallback for the
    /// rest of this launch, so later steps don't pay for a failed call.
    private var firstModelIndexToTry = 0

    private let session: URLSession
    private let apiKeyProvider: @MainActor @Sendable () -> String?

    init(
        apiKeyProvider: @escaping @MainActor @Sendable () -> String? = { KeychainStore.geminiAPIKey },
        session: URLSession? = nil
    ) {
        self.apiKeyProvider = apiKeyProvider
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            // One shared session keeps the TLS connection warm between steps.
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 45
            self.session = URLSession(configuration: configuration)
        }
    }

    func plan(
        task: String,
        history: [String],
        appName: String?,
        elements: [CombinedPlannerElement],
        screenshotJPEGBase64: String?,
        reviewNote: String? = nil
    ) async throws -> (decision: CombinedPlannerDecision, milliseconds: Int, inputTokens: Int) {
        guard let apiKey = await apiKeyProvider(), !apiKey.isEmpty else {
            throw GeminiFlashPlannerError.missingAPIKey
        }

        let body = try GeminiFlashPlanning.requestBody(
            task: task,
            history: history,
            appName: appName,
            elements: elements,
            screenshotJPEGBase64: screenshotJPEGBase64,
            reviewNote: reviewNote
        )

        let requestBodyData = try JSONSerialization.data(withJSONObject: body)
        let startedAt = DispatchTime.now().uptimeNanoseconds
        var lastModelError: GeminiFlashPlannerError?

        for modelIndex in firstModelIndexToTry..<GeminiFlashPlanning.modelIDs.count {
            try Task.checkCancellation()
            let modelID = GeminiFlashPlanning.modelIDs[modelIndex]
            var request = URLRequest(url: Self.endpoint(forModelID: modelID))
            request.httpMethod = "POST"
            // Header, not query string, so the key never appears in URL logs.
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = requestBodyData

            let (responseData, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw GeminiFlashPlannerError.malformed("no HTTP response")
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                let modelError = GeminiFlashPlannerError.http(
                    status: httpResponse.statusCode,
                    body: "\(modelID): " + (String(data: responseData, encoding: .utf8) ?? "")
                )
                guard GeminiFlashPlanning.shouldTryNextModel(afterHTTPStatus: httpResponse.statusCode) else {
                    throw modelError
                }
                print("[GeminiFlashPlanner] \(modelID) returned \(httpResponse.statusCode), trying the next model")
                lastModelError = modelError
                continue
            }

            firstModelIndexToTry = modelIndex
            let elapsedMilliseconds = Int((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
            let (answerText, inputTokens) = try GeminiFlashPlanning.answerText(fromResponseData: responseData)
            let decision = try GeminiFlashPlanning.decision(fromAnswerText: answerText, elements: elements)
            return (decision, elapsedMilliseconds, inputTokens)
        }

        // Every model was overloaded. Start from the top again next step,
        // since overload is usually brief.
        firstModelIndexToTry = 0
        throw lastModelError ?? GeminiFlashPlannerError.malformed("no Gemini Flash model available")
    }
}
