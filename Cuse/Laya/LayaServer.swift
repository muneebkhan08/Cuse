import Foundation

/// Starts the on-device Laya decision server from the install at
/// `~/Library/Application Support/Cuse/laya` and waits until it can answer.
enum LayaServer {
    static let host = "127.0.0.1"
    static let port = 8765
    static let endpoint = URL(string: "http://\(host):\(port)/v1/systemone")!

    private static let lock = NSLock()
    private static var process: Process?
    private static var bootTask: Task<Void, Error>?

    static var installDirectory: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let cuseInstallDirectory = baseURL
            .appendingPathComponent("Cuse", isDirectory: true)
            .appendingPathComponent("laya", isDirectory: true)
        // Installs made before the TipTour → Cuse rebrand live under the old
        // folder. A virtualenv can't simply be moved, so keep using it until
        // a fresh install exists at the Cuse path.
        let legacyTipTourInstallDirectory = baseURL
            .appendingPathComponent("TipTour", isDirectory: true)
            .appendingPathComponent("laya", isDirectory: true)
        let cuseInstallExists = FileManager.default.fileExists(atPath: cuseInstallDirectory.path)
        let legacyTipTourInstallExists = FileManager.default.fileExists(atPath: legacyTipTourInstallDirectory.path)
        if !cuseInstallExists && legacyTipTourInstallExists {
            return legacyTipTourInstallDirectory
        }
        return cuseInstallDirectory
    }

    static func ensureRunning() async throws {
        if await isHealthy() { return }
        let task: Task<Void, Error> = lock.withLock {
            if let bootTask { return bootTask }
            let created = Task { try await boot() }
            bootTask = created
            return created
        }
        defer { lock.withLock { bootTask = nil } }
        try await task.value
    }

    private static func boot() async throws {
        if await isHealthy() { return }
        let pythonURL = installDirectory.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: pythonURL.path) else {
            throw LayaServerError.missingInstall(installDirectory.path)
        }
        guard let scriptURL = bundledScriptURL() else {
            throw LayaServerError.missingScript
        }

        let logURL = installDirectory.appendingPathComponent("server.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        guard let logHandle = try? FileHandle(forWritingTo: logURL) else {
            throw LayaServerError.couldNotStart("Could not open \(logURL.path)")
        }
        try logHandle.seekToEnd()

        let process = Process()
        process.executableURL = pythonURL
        process.arguments = [scriptURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["LAYA_HOME"] = installDirectory.path
        environment["LAYA_HOST"] = host
        environment["LAYA_PORT"] = String(port)
        environment["HF_HOME"] = installDirectory.appendingPathComponent("hf").path
        environment["HF_HUB_CACHE"] = installDirectory.appendingPathComponent("hf/hub").path
        environment["HUGGINGFACE_HUB_CACHE"] = installDirectory.appendingPathComponent("hf/hub").path
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        process.environment = environment
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
        } catch {
            throw LayaServerError.couldNotStart(error.localizedDescription)
        }
        lock.withLock { self.process = process }

        // The multilingual weights are already on disk. Loading them onto the
        // GPU is the slow part of the first request, so wait here instead of
        // inside a click decision.
        for _ in 0..<120 {
            try Task.checkCancellation()
            if await isHealthy() { return }
            if !process.isRunning {
                throw LayaServerError.couldNotStart(logTail(logURL))
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw LayaServerError.couldNotStart(logTail(logURL))
    }

    private static func isHealthy() async -> Bool {
        var request = URLRequest(url: URL(string: "http://\(host):\(port)/health")!)
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              payload["service"] as? String == "cuse-laya",
              payload["model"] as? String == "multilingual" else {
            return false
        }
        return true
    }

    private static func bundledScriptURL() -> URL? {
        // Debug builds keep this file next to LayaServer.swift. `#filePath` is
        // the path from the machine that compiled the app.
        let besideSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("laya_systemone.py")
        if FileManager.default.fileExists(atPath: besideSource.path) {
            return besideSource
        }
        if let resourceURL = Bundle.main.url(forResource: "laya_systemone", withExtension: "py") {
            return resourceURL
        }
        if let resourceURL = Bundle.main.url(forResource: "laya_systemone", withExtension: "py", subdirectory: "Laya") {
            return resourceURL
        }
        var cursor = Bundle.main.bundleURL
        for _ in 0..<8 {
            let candidate = cursor.appendingPathComponent("Cuse/Laya/laya_systemone.py")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            cursor.deleteLastPathComponent()
        }
        return nil
    }

    private static func logTail(_ logURL: URL) -> String {
        guard let data = try? Data(contentsOf: logURL),
              let text = String(data: data, encoding: .utf8) else {
            return "Laya exited before it could answer. See \(logURL.path)"
        }
        let tail = text.split(separator: "\n").suffix(12).joined(separator: "\n")
        return tail.isEmpty ? "Laya exited before it could answer. See \(logURL.path)" : tail
    }
}

enum LayaServerError: LocalizedError {
    case missingInstall(String)
    case missingScript
    case couldNotStart(String)

    var errorDescription: String? {
        switch self {
        case let .missingInstall(path):
            return "Laya is not installed at \(path). The text mode needs that local virtualenv and the multilingual checkpoint."
        case .missingScript:
            return "Cuse could not find laya_systemone.py in the app bundle."
        case let .couldNotStart(detail):
            return "Laya did not start. \(detail)"
        }
    }
}
