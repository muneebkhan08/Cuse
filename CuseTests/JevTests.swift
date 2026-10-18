import Foundation
import Testing
@testable import Cuse

@MainActor
struct JevTests {
    @Test func targetContinuityAllowsJitterButRejectsDifferentControls() {
        func matches(_ box: [Double], label: String = "New Tab", source: String = "ocr",
                     display: [Double] = [0, 0, 1512, 982]) -> Bool {
            LocalTargetContinuity.matches(label: label, source: source, box: box, display: display,
                previousLabel: "New Tab", previousSource: "ocr", previousBox: [100, 50, 160, 65],
                previousDisplay: [0, 0, 1512, 982])
        }
        #expect(matches([101, 49, 161, 66]))
        #expect(!matches([500, 50, 560, 65]))
        #expect(!matches([100, 50, 160, 65], label: "Close Tab"))
        #expect(!matches([100, 50, 160, 65], display: [1512, 0, 1512, 982]))
        #expect(!matches([100, 50, 160, 65], source: "yolo"))
        #expect(!matches([100, 50]))
    }

    private let metrics = JevCallMetrics(milliseconds: 1, inputTokens: 100, model: "jev-latest")
    private func candidate(_ id: String = "save", label: String = "Save") -> JevCandidate {
        JevCandidate(id: id, label: label, source: "ocr", confidence: 1, centre: .zero)
    }
    private func answers(choice: String = "save", absent: Double = 0.1,
                         probability: Double = 0.9, kind: String = "click") throws -> [String: JevAnswer] {
        let data = try JSONSerialization.data(withJSONObject: [
            "pick": ["choice": choice, "probabilities": [choice: probability]],
            "done": ["noul": 0.1], "absent": ["noul": absent], "kind": ["choice": kind]
        ])
        return try JSONDecoder().decode([String: JevAnswer].self, from: data)
    }

    @Test func defaultModeIsJevAndSavedChoiceIsRespected() {
        #expect(CuseMode.restored(from: nil) == .jev)
        #expect(CuseMode.restored(from: "obsolete-provider") == .jev)
        #expect(CuseMode.restored(from: "gemini") == .gemini)
        #expect(CuseMode.restored(from: "jev") == .jev)
    }

    @Test func microphoneIsRequiredOnlyForGemini() {
        #expect(CuseMode.jev.permissionsReady(desktop: true, microphone: false))
        #expect(!CuseMode.gemini.permissionsReady(desktop: true, microphone: false))
        #expect(CuseMode.gemini.permissionsReady(desktop: true, microphone: true))
        #expect(!CuseMode.jev.permissionsReady(desktop: false, microphone: true))
    }

    @Test func selectedModeUsesItsOwnKeyAndShortcut() {
        #expect(CuseMode.jev.title == "Laya")
        #expect(!CuseMode.jev.requiresAPIKey)
        #expect(CuseMode.gemini.requiresAPIKey)
        #expect(CuseMode.jev.keyName == "jevAPIKey")
        #expect(CuseMode.gemini.keyName == "geminiAPIKey")
        #expect(CuseMode.jev.shortcut == "Ctrl+K")
        #expect(CuseMode.gemini.shortcut == "Ctrl+Option")
    }

    @Test func combinedModeSharesGeminiKeyAndUsesTextPanelWithoutMicrophone() {
        #expect(CuseMode.restored(from: "combined") == .combined)
        #expect(CuseMode.combined.requiresAPIKey)
        #expect(CuseMode.combined.keyName == CuseMode.gemini.keyName)
        #expect(CuseMode.combined.shortcut == "Ctrl+L")
        #expect(CuseMode.combined.usesTextCommandPanel)
        #expect(!CuseMode.gemini.usesTextCommandPanel)
        #expect(CuseMode.combined.permissionsReady(desktop: true, microphone: false))
        #expect(!CuseMode.combined.permissionsReady(desktop: false, microphone: true))
    }

    private let plannerElements = [
        CombinedPlannerElement(id: "save", label: "Save", source: "ocr", normalizedBox2D: [10, 20, 30, 40]),
        CombinedPlannerElement(id: "cancel", label: "Cancel", source: "ax", normalizedBox2D: [10, 50, 30, 70])
    ]

    @Test func plannerDecisionKeepsRealTargetAndDropsInventedIDs() throws {
        let realTarget = try GeminiFlashPlanning.decision(
            fromAnswerText: #"{"status":"act","remaining_plan":["Click Save"],"action":"click","target_id":"save","target_description":"the Save button","message":""}"#,
            elements: plannerElements)
        #expect(realTarget.action == .click)
        #expect(realTarget.targetID == "save")
        #expect(realTarget.remainingPlan == ["Click Save"])

        let inventedTarget = try GeminiFlashPlanning.decision(
            fromAnswerText: #"{"status":"act","remaining_plan":[],"action":"click","target_id":"e999","target_description":"the Save button","message":""}"#,
            elements: plannerElements)
        #expect(inventedTarget.targetID == nil)
        #expect(inventedTarget.targetDescription == "the Save button")
    }

    @Test func plannerDecisionRejectsIncompleteActions() {
        #expect(throws: GeminiFlashPlannerError.self) {
            try GeminiFlashPlanning.decision(
                fromAnswerText: #"{"status":"act","remaining_plan":[],"action":"type","text":"  ","message":""}"#,
                elements: self.plannerElements)
        }
        #expect(throws: GeminiFlashPlannerError.self) {
            try GeminiFlashPlanning.decision(
                fromAnswerText: #"{"status":"act","remaining_plan":[],"action":"click","target_id":"e999","message":""}"#,
                elements: self.plannerElements)
        }
        #expect(throws: GeminiFlashPlannerError.self) {
            try GeminiFlashPlanning.decision(
                fromAnswerText: #"{"status":"act","remaining_plan":[],"action":"drag","message":""}"#,
                elements: self.plannerElements)
        }
        #expect(throws: GeminiFlashPlannerError.self) {
            try GeminiFlashPlanning.decision(fromAnswerText: #"{"status":"maybe"}"#, elements: self.plannerElements)
        }
    }

    @Test func plannerDecisionReadsNonActionStatuses() throws {
        let needsScreenshot = try GeminiFlashPlanning.decision(
            fromAnswerText: #"{"status":"need_screenshot","remaining_plan":[],"message":"icons only"}"#,
            elements: plannerElements)
        #expect(needsScreenshot.status == .needScreenshot)
        #expect(needsScreenshot.action == nil)

        let typing = try GeminiFlashPlanning.decision(
            fromAnswerText: #"{"status":"act","remaining_plan":["Type name"],"action":"type","text":"Report","message":""}"#,
            elements: plannerElements)
        #expect(typing.action == .type)
        #expect(typing.text == "Report")
        #expect(!(typing.action?.needsScreenTarget ?? true))
    }

    @Test func plannerRequestAttachesScreenshotOnlyWhenGiven() throws {
        func userParts(_ screenshot: String?, review: String? = nil) throws -> [[String: Any]] {
            let body = try GeminiFlashPlanning.requestBody(
                task: "Save the file", history: [], appName: "TextEdit",
                elements: plannerElements, screenshotJPEGBase64: screenshot, reviewNote: review)
            let contents = try #require(body["contents"] as? [[String: Any]])
            return try #require(contents.first?["parts"] as? [[String: Any]])
        }
        #expect(try userParts(nil).count == 1)
        let withScreenshot = try userParts("AAAA")
        #expect(withScreenshot.count == 2)
        #expect((withScreenshot[1]["inlineData"] as? [String: Any])?["data"] as? String == "AAAA")

        let contextText = try #require(try userParts(nil, review: "look again").first?["text"] as? String)
        #expect(contextText.contains("\"review\":\"look again\""))
        #expect(contextText.contains("\"id\":\"save\""))
        #expect(!contextText.contains("globalCenter"))
    }

    @Test func plannerFallsBackOnlyWhenAModelIsUnavailable() {
        #expect(GeminiFlashPlanning.modelIDs.last == "gemini-3.7-flash")
        for overloadedStatus in [404, 429, 500, 502, 503, 504] {
            #expect(GeminiFlashPlanning.shouldTryNextModel(afterHTTPStatus: overloadedStatus))
        }
        for realFailureStatus in [400, 401, 403] {
            #expect(!GeminiFlashPlanning.shouldTryNextModel(afterHTTPStatus: realFailureStatus))
        }
    }

    @Test func rejectedKeyGetsAPlainMessage() {
        #expect(GeminiFlashPlannerError.isRejectedAPIKey(status: 401, body: ""))
        #expect(GeminiFlashPlannerError.isRejectedAPIKey(status: 400, body: #"{"reason":"API_KEY_INVALID"}"#))
        #expect(!GeminiFlashPlannerError.isRejectedAPIKey(status: 503, body: ""))
        #expect(GeminiFlashPlannerError.http(status: 401, body: "").errorDescription?.contains("Settings → Models") == true)
    }

    @Test func relevantCandidatesSurviveTheCandidateCap() {
        let noise = (0..<250).map { candidate("noise-\($0)", label: "Item \($0)") }
        let target = candidate("wiki-english", label: "English")
        let request = JevGrounding.request(task: "Click English", candidates: noise + [target],
                                           history: [], excluding: [])
        #expect(request?.pool.count == JevGrounding.maxCandidates)
        #expect(request?.pool.first?.id == "wiki-english")

        let unlabeled = candidate("blank", label: "")
        let ordered = JevGrounding.relevanceOrdered([unlabeled, candidate("a", label: "Cancel")], task: "anything")
        #expect(ordered.last?.id == "blank")
    }

    @Test func screenRegionReadsAppKitCoordinatesFromTheTop() {
        let display = CGRect(x: 0, y: 0, width: 1500, height: 900)
        // AppKit global points: the menu bar has the largest y.
        #expect(JevGrounding.screenRegion(forCentre: CGPoint(x: 100, y: 880), displayFrame: display) == "top-left")
        #expect(JevGrounding.screenRegion(forCentre: CGPoint(x: 750, y: 450), displayFrame: display) == "middle-center")
        #expect(JevGrounding.screenRegion(forCentre: CGPoint(x: 1400, y: 50), displayFrame: display) == "bottom-right")
        #expect(JevGrounding.screenRegion(forCentre: .zero, displayFrame: .zero) == "")
        var described = candidate()
        described.screenRegion = "top-left"
        #expect(described.describedForJev.contains("in the top-left of the screen"))
    }

    @Test func focusedShortlistPrefersRareSpecificWords() {
        // Mirrors the measured Wikipedia page: many labels say "Wikipedia".
        let page = [candidate("tab", label: "API keys | Google AI Studio"), candidate("de", label: "Deutsch"),
                    candidate("en", label: "English"), candidate("url", label: "wikipedia.org")]
            + (0..<8).map { candidate("wp\($0)", label: "Wikipedia") }
        #expect(JevGrounding.focusedShortlist(page, task: "Click English")?.map(\.id) == ["en"])
        #expect(JevGrounding.focusedShortlist(page, task: "Open the Deutsch Wikipedia")?.map(\.id) == ["de"])
        // Only a generic word matches, so Laya keeps the full list.
        #expect(JevGrounding.focusedShortlist(page, task: "Open the German Wikipedia") == nil)
        #expect(JevGrounding.focusedShortlist(page, task: "Open settings") == nil)
        // A shared word on only a few labels still focuses Laya.
        let searchPage = [candidate("s1", label: "Search"), candidate("s2", label: "Search Wikipedia"),
                          candidate("s3", label: "Search"), candidate("s4", label: "Search Wikipedia"),
                          candidate("tab", label: "New tab"), candidate("file", label: "File")]
        #expect(Set(JevGrounding.focusedShortlist(searchPage, task: "Click the search box and search for Alan Turing")?.map(\.id) ?? [])
                == ["s1", "s2", "s3", "s4"])
        let request = JevGrounding.request(task: "Click English", candidates: page, history: [], excluding: [],
                                           useFocusedShortlist: true)
        #expect(request?.pool.map(\.id) == ["en"])
    }

    @Test func textFieldShapeSteersTheFirstClickOfATypingTask() {
        // Measured Wikipedia boxes: search field 415x39, Search button 70x34.
        #expect(JevGrounding.isTextFieldShaped(source: "yolo", globalBox: [498, 851, 913, 890]))
        #expect(!JevGrounding.isTextFieldShaped(source: "yolo", globalBox: [908, 853, 978, 887]))
        #expect(!JevGrounding.isTextFieldShaped(source: "ocr", globalBox: [538, 861, 652, 875]))
        var field = candidate("field", label: "Search Wikipedia")
        field.isTextFieldShaped = true
        #expect(field.describedForJev.contains("(wide text-field shape)"))
        let button = candidate("button", label: "Search")
        #expect(JevGrounding.preferringTextField([(button, 0.29), (field, 0.22)])?.candidate.id == "field")
        #expect(JevGrounding.preferringTextField([(button, 0.60), (field, 0.20)])?.candidate.id == "button")
        let pendingOptions = JevGrounding.actionKindOptions(task: "search for cats", history: [], allowTyping: true)
        #expect(Set(pendingOptions.keys) == ["click"])
    }

    @Test func typingTaskFindsItsFieldButNotBrowserTabs() {
        var field = candidate("field", label: "Search Wikipedia")
        field.isTextFieldShaped = true
        let tab = candidate("tab", label: "Search - Wikipedia")
        let button = candidate("button", label: "Search")
        let task = "Click the search box and search for Alan Turing"
        #expect(JevGrounding.textFieldMatchingTask([tab, button, field], task: task)?.id == "field")
        #expect(JevGrounding.textFieldMatchingTask([tab, button], task: task) == nil)
        var unrelatedField = candidate("url", label: "wikipedia.org")
        unrelatedField.isTextFieldShaped = true
        #expect(JevGrounding.textFieldMatchingTask([unrelatedField], task: task) == nil)
    }

    @Test func simpleTasksKnowWhenTheyAreDone() {
        #expect(JevGrounding.isSingleActionTask("Click English"))
        #expect(JevGrounding.isSingleActionTask("Open the Deutsch Wikipedia"))
        #expect(!JevGrounding.isSingleActionTask("Click File and then Save"))
        #expect(!JevGrounding.isSingleActionTask("search for cats"))
        #expect(!JevGrounding.isSingleActionTask("Calculate 12 plus 30"))
        #expect(JevGrounding.taskEndsAfterSubmittingTypedText("search for cute cats"))
        #expect(JevGrounding.taskEndsAfterSubmittingTypedText("Click the search box and search for Alan Turing then press enter"))
        #expect(JevGrounding.taskEndsAfterSubmittingTypedText("type 'hello'"))
        #expect(!JevGrounding.taskEndsAfterSubmittingTypedText("search for cats and open the first result"))
    }

    @Test func textToTypeComesOnlyFromTheUsersTask() {
        #expect(JevGrounding.textToType(fromTask: "search for cute cats on google") == "cute cats")
        #expect(JevGrounding.textToType(fromTask: "Type 'hello world' in the notes field") == "hello world")
        #expect(JevGrounding.textToType(fromTask: "click the search box and type Anthropic then press enter") == "Anthropic")
        #expect(JevGrounding.textToType(fromTask: "Click the Search button") == nil)
        #expect(JevGrounding.textToType(fromTask: "Open settings") == nil)
    }

    @Test func typingIsOfferedOnlyRightAfterAClickAndOnce() {
        let task = "search for cats"
        #expect(JevGrounding.actionKindOptions(task: task, history: [], allowTyping: true)["type_text"] == nil)
        let afterClick = JevGrounding.actionKindOptions(task: task, history: ["click Search: completed"], allowTyping: true)
        #expect(afterClick["type_text"]?.contains("cats") == true)
        #expect(afterClick["press_enter"] == nil)
        let afterTyping = JevGrounding.actionKindOptions(
            task: task, history: ["click Search: completed", "type_text \"cats\": completed"], allowTyping: true)
        #expect(afterTyping["type_text"] == nil)
        #expect(afterTyping["press_enter"] != nil)
        #expect(JevGrounding.actionKindOptions(task: task, history: ["click Search: completed"], allowTyping: false)["type_text"] == nil)
    }

    @Test func typingChoiceIsAcceptedOnlyWhenOffered() throws {
        let typed = try answers(kind: "type_text")
        #expect(throws: JevError.self) {
            try JevGrounding.decision(from: typed, pool: [self.candidate()], metrics: self.metrics)
        }
        let decision = try JevGrounding.decision(from: typed, pool: [candidate()], metrics: metrics,
                                                 allowedActionKinds: ["click", "type_text"])
        #expect(decision.actionKind == "type_text")
    }

    @Test func plannerAnswerTextSkipsThoughtParts() throws {
        let responseData = Data(#"""
        {"candidates":[{"content":{"parts":[{"text":"thinking...","thought":true},{"text":"{\"status\":\"done\"}"}]}}],
         "usageMetadata":{"promptTokenCount":42}}
        """#.utf8)
        let (answerText, inputTokens) = try GeminiFlashPlanning.answerText(fromResponseData: responseData)
        #expect(answerText == #"{"status":"done"}"#)
        #expect(inputTokens == 42)
        #expect(throws: GeminiFlashPlannerError.self) {
            try GeminiFlashPlanning.answerText(fromResponseData: Data(#"{"promptFeedback":{"blockReason":"SAFETY"}}"#.utf8))
        }
    }

    @Test func requestsStayUnderAPILimitAndKeepNoneOption() {
        let candidates = (0..<300).map { candidate("id-\($0)", label: "Button \($0)") }
        let request = JevGrounding.request(task: "Save", candidates: candidates, history: [], excluding: [])
        #expect(request?.pool.count == 200)
        if case let .choice(_, criteria) = request?.questions["pick"] {
            #expect(criteria.count == 201)
            #expect(criteria[JevGrounding.noneKey] != nil)
        } else { Issue.record("Missing bounded choice question") }
    }

    @Test func duplicateAndReservedIDsCannotCrashCandidateDictionary() {
        let request = JevGrounding.request(task: "Save", candidates: [
            candidate(), candidate(label: "Different label"), candidate("__none__"), candidate("")
        ], history: [], excluding: [])
        #expect(request?.pool.count == 1)
    }

    @Test func noneChoiceStopsInsteadOfClickingRunnerUp() throws {
        var payload = try answers(choice: "__none__")
        payload["pick"] = try JSONDecoder().decode(JevAnswer.self, from: Data(
            #"{"choice":"__none__","probabilities":{"__none__":0.9,"save":0.1}}"#.utf8))
        let result = try JevGrounding.decision(from: payload, pool: [candidate()], metrics: metrics)
        #expect(result.best?.candidate.id == "save")
        #expect(result.stopReason == "target_absent")
    }

    @Test func topTargetIsAllowedRegardlessOfAbsentScoreOrProbability() throws {
        let absent = try JevGrounding.decision(from: answers(absent: 0.9), pool: [candidate()], metrics: metrics)
        let weak = try JevGrounding.decision(from: answers(probability: 0.2), pool: [candidate()], metrics: metrics)
        #expect(absent.stopReason == nil)
        #expect(absent.best?.candidate.id == "save")
        #expect(weak.stopReason == nil)
        #expect(weak.best?.candidate.id == "save")
    }

    @Test func inventedTargetOrActionAndIncompleteResponsesAreRejected() throws {
        #expect(throws: JevError.self) {
            try JevGrounding.decision(from: answers(choice: "invented"), pool: [candidate()], metrics: metrics)
        }
        #expect(throws: JevError.self) {
            try JevGrounding.decision(from: answers(kind: "type"), pool: [candidate()], metrics: metrics)
        }
        #expect(throws: JevError.self) {
            try JevGrounding.decision(from: [:], pool: [candidate()], metrics: metrics)
        }
    }

    @Test func closeGestureCallBecomesASingleClick() throws {
        var payload = try answers()
        payload["kind"] = try JSONDecoder().decode(JevAnswer.self, from: Data(
            #"{"choice":"double_click","probabilities":{"click":0.37,"double_click":0.40,"right_click":0.23}}"#.utf8))
        let decision = try JevGrounding.decision(from: payload, pool: [candidate()], metrics: metrics)
        #expect(decision.actionKind == "click")
    }

    @Test func clearRightClickIsKept() throws {
        var payload = try answers()
        payload["kind"] = try JSONDecoder().decode(JevAnswer.self, from: Data(
            #"{"choice":"right_click","probabilities":{"click":0.10,"double_click":0.10,"right_click":0.80}}"#.utf8))
        let decision = try JevGrounding.decision(from: payload, pool: [candidate()], metrics: metrics)
        #expect(decision.actionKind == "right_click")
    }

    @Test func validClickUsesSuppliedTarget() throws {
        let decision = try JevGrounding.decision(from: answers(), pool: [candidate()], metrics: metrics)
        #expect(decision.best?.candidate.id == "save")
        #expect(decision.actionKind == "click")
        #expect(decision.stopReason == nil)
    }

    @Test func roundedTieHonorsTheSelectedOption() throws {
        var payload = try answers()
        payload["pick"] = try JSONDecoder().decode(JevAnswer.self, from: Data(
            #"{"choice":"save","probabilities":{"cancel":0.5,"save":0.5}}"#.utf8))
        let result = try JevGrounding.decision(from: payload,
            pool: [candidate(), candidate("cancel", label: "Cancel")], metrics: metrics)
        #expect(result.best?.candidate.id == "save")
    }

    @Test func localLayaCallDoesNotRequireAnAPIKey() async throws {
        LocalLayaURLProtocol.lastBody = Data()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalLayaURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = JevClient(apiKeyProvider: { nil }, session: session)
        let result = try await client.ask(
            state: ["task": "Save"],
            questions: ["kind": .choice(instructions: "How?", criteria: ["click": "left click"])]
        )
        #expect(result.metrics.model == "multilingual")
        #expect(LocalLayaURLProtocol.lastRequest?.url?.host == "127.0.0.1")
        #expect(LocalLayaURLProtocol.lastRequest?.url?.port == 8765)
        #expect(LocalLayaURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == nil)
        let payload = try JSONSerialization.jsonObject(with: LocalLayaURLProtocol.lastBody) as? [String: Any]
        #expect(payload?["model"] == nil)
        #expect(payload?["state"] != nil)
    }
}

/// Stands in for the local Laya server so the client test never opens a socket.
final class LocalLayaURLProtocol: URLProtocol {
    static var lastRequest: URLRequest?
    static var lastBody = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        if let body = request.httpBody {
            Self.lastBody = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            Self.lastBody = data
        }
        let responseBody = Data(#"{"answers":{},"model":"multilingual","usage":{"input_tokens":3,"output_tokens":0}}"#.utf8)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "http://127.0.0.1:8765/v1/systemone")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
