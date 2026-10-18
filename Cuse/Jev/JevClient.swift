import Foundation

// MARK: - Questions

/// One question in a Jev request. Only the question shapes used by the pointer loop.
nonisolated enum JevQuestion {
    /// Probability that a statement is true. The answer has NO confidence and
    /// NO probabilities — just `noul`.
    case noul(instructions: String, criteria: [String: String]? = nil)
    /// Pick exactly one key. `criteria` maps option key → what that option
    /// means; both the key and the value are read semantically, so put a real
    /// label in at least one of them.
    case choice(instructions: String, criteria: [String: String])

    var payload: [String: Any] {
        switch self {
        case let .noul(instructions, criteria):
            var body: [String: Any] = ["type": "noul", "instructions": instructions]
            if let criteria { body["criteria"] = criteria }
            return body
        case let .choice(instructions, criteria):
            return ["type": "choice", "instructions": instructions, "criteria": criteria]
        }
    }
}

// MARK: - Answers

/// One answer. Which fields are populated depends on the question type:
/// `noul` fills only `noul`; `choice` fills `choice`/`confidence`/`probabilities`;
/// `score` fills `score`/`confidence`/`probabilities`.
nonisolated struct JevAnswer: Decodable {
    let type: String?
    let noul: Double?
    let choice: String?
    let score: Double?
    let confidence: Double?
    let probabilities: [String: Double]?

    /// Options sorted most-likely first. The API returns `probabilities` in
    /// shuffled key order, so never read it positionally.
    var ranked: [(key: String, probability: Double)] {
        (probabilities ?? [:])
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }
            .map { (key: $0.key, probability: $0.value) }
    }

    /// The number to threshold on. `confidence` is chance-corrected and so
    /// shifts as the candidate count changes between steps; this does not.
    var topProbability: Double { ranked.first?.probability ?? 0 }

    /// How far clear the winner is of the runner-up. A better "should I act on
    /// this" signal than either probability alone when two candidates are close.
    var margin: Double {
        let sorted = ranked
        guard sorted.count >= 2 else { return sorted.first?.probability ?? 0 }
        return sorted[0].probability - sorted[1].probability
    }
}

nonisolated struct JevResponse: Decodable {
    let answers: [String: JevAnswer]
    let model: String?
    let usage: Usage?

    struct Usage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
    }
}

/// What one call cost and how long it took, for the UI to show honestly.
nonisolated struct JevCallMetrics {
    let milliseconds: Int
    let inputTokens: Int
    let model: String
}

nonisolated enum JevError: LocalizedError {
    case missingAPIKey
    case tooManyChoices(Int)
    case http(status: Int, body: String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Laya is not ready. Start a text command again so Cuse can launch the local model."
        case let .tooManyChoices(count):
            return "Jev accepts at most \(JevClient.maxChoices) options in one question; this call had \(count)."
        case let .http(status, body):
            return "Jev returned \(status): \(body.prefix(300))"
        case let .malformed(detail):
            return "Jev sent something unreadable: \(detail)"
        }
    }
}

// MARK: - Client

actor JevClient {
    /// On-device Laya at the same port `LayaServer` binds. The server pins
    /// `multilingual`, the checkpoint in Application Support/Cuse/laya.
    static let endpoint = URL(string: "http://127.0.0.1:8765/v1/systemone")!
    static let maxChoices = 255

    static let shared = JevClient()

    private let session: URLSession
    private let apiKeyProvider: @MainActor @Sendable () -> String?

    init(
        apiKeyProvider: @escaping @MainActor @Sendable () -> String? = { KeychainStore.jevAPIKey },
        session: URLSession? = nil
    ) {
        self.apiKeyProvider = apiKeyProvider
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            // Reuse the session so consecutive steps can reuse the connection.
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 90
            configuration.httpMaximumConnectionsPerHost = 4
            self.session = URLSession(configuration: configuration)
        }
    }

    /// Ask one batch of questions about one state. Bundle everything you want
    /// to know about a screen into a single call: the state is billed once and
    /// extra questions are nearly free.
    func ask(
        state: [String: Any],
        questions: [String: JevQuestion]
    ) async throws -> (answers: [String: JevAnswer], metrics: JevCallMetrics) {
        let key = await apiKeyProvider()

        for question in questions.values {
            if case let .choice(_, criteria) = question, criteria.count > Self.maxChoices {
                throw JevError.tooManyChoices(criteria.count)
            }
        }

        let body: [String: Any] = [
            "state": state,
            "questions": questions.mapValues(\.payload)
        ]

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        if let key, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = DispatchTime.now().uptimeNanoseconds
        let (data, response) = try await session.data(for: request)
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)

        guard let http = response as? HTTPURLResponse else {
            throw JevError.malformed("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw JevError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        let decoded: JevResponse
        do {
            decoded = try JSONDecoder().decode(JevResponse.self, from: data)
        } catch {
            throw JevError.malformed(error.localizedDescription)
        }

        let metrics = JevCallMetrics(
            milliseconds: elapsed,
            inputTokens: decoded.usage?.input_tokens ?? 0,
            model: decoded.model ?? "multilingual"
        )
        return (decoded.answers, metrics)
    }
}
