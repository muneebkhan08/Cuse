//
//  CuseHighlightSourceResolver.swift
//  Cuse
//
//  Resolves "what did the user highlight?" into a file, URL, text selection,
//  or screenshot-only source plus the tools that make sense for that source.
//

import AppKit
import ApplicationServices
import Foundation

struct CuseHighlightSourceRequest: Decodable {
    let sourceFilePath: String?
    let source_file_path: String?
    let traceID: String?
    let trace_id: String?

    init() {
        self.sourceFilePath = nil
        self.source_file_path = nil
        self.traceID = nil
        self.trace_id = nil
    }

    var normalizedSourceFilePath: String? {
        firstNonEmpty(sourceFilePath, source_file_path)
    }

    var normalizedTraceID: String? {
        firstNonEmpty(traceID, trace_id)
    }

    private func firstNonEmpty(_ values: String?...) -> String? {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

struct CuseHighlightSourceResponse: Encodable {
    let ok: Bool
    let traceID: String
    let source: CuseHighlightSourceResolution

    private enum CodingKeys: String, CodingKey {
        case ok
        case traceID = "trace_id"
        case source
    }
}

struct CuseHighlightSourceResolution: Encodable {
    let ok: Bool
    let kind: String
    let source: String
    let filePath: String?
    let sourceURL: String?
    let appName: String?
    let bundleIdentifier: String?
    let processIdentifier: Int?
    let windowTitle: String?
    let confidence: Double
    let reason: String?
    let message: String?
    let contentCategory: String
    let fileExtension: String?
    let mimeType: String?
    let selectedText: String?
    let highlightScreenRect: [Double]?
    let tools: [CuseHighlightToolCapability]

    private enum CodingKeys: String, CodingKey {
        case ok
        case kind
        case source
        case filePath = "file_path"
        case sourceURL = "source_url"
        case appName = "app_name"
        case bundleIdentifier = "bundle_identifier"
        case processIdentifier = "process_identifier"
        case windowTitle = "window_title"
        case confidence
        case reason
        case message
        case contentCategory = "content_category"
        case fileExtension = "file_extension"
        case mimeType = "mime_type"
        case selectedText = "selected_text"
        case highlightScreenRect = "highlight_screen_rect"
        case tools
    }
}

struct CuseHighlightToolCapability: Encodable {
    let id: String
    let title: String
    let endpoint: String?
    let mode: String
    let reason: String
}

enum CuseHighlightSourceResolver {
    static func resolve(
        explicitFilePath: String?,
        highlightContext: FocusHighlightContext?,
        fallbackApplication: NSRunningApplication? = nil
    ) -> CuseHighlightSourceResolution {
        if let explicitFilePath,
           let resolution = resolutionForLocalFile(
            path: explicitFilePath,
            source: "request.source_file_path",
            appContext: highlightContext?.hoveredWindow,
            highlightContext: highlightContext,
            confidence: 1
           ) {
            return resolution
        }

        if let highlightContext,
           let axResolution = resolveFromAccessibility(highlightContext: highlightContext) {
            return axResolution
        }

        if let highlightContext,
           let scriptResolution = resolveFromAppleScript(windowContext: highlightContext.hoveredWindow, highlightContext: highlightContext) {
            return scriptResolution
        }

        if let highlightContext,
           let browserResolution = resolveBrowserURL(windowContext: highlightContext.hoveredWindow, highlightContext: highlightContext) {
            return browserResolution
        }

        if let highlightContext,
           let fallbackWindowContext = windowContext(for: fallbackApplication),
           fallbackWindowContext.bundleIdentifier != highlightContext.hoveredWindow?.bundleIdentifier {
            if let scriptResolution = resolveFromAppleScript(windowContext: fallbackWindowContext, highlightContext: highlightContext) {
                return scriptResolution
            }
            if let browserResolution = resolveBrowserURL(windowContext: fallbackWindowContext, highlightContext: highlightContext) {
                return browserResolution
            }
        }

        return enrichedResolution(
            ok: false,
            kind: "screenshot_only",
            source: "highlight_screenshot",
            filePath: nil,
            sourceURL: nil,
            appContext: highlightContext?.hoveredWindow,
            highlightContext: highlightContext,
            confidence: 0.25,
            reason: "source_file_unresolved",
            message: "Could not resolve a local file or URL. Cuse can still provide visual context for the highlighted region."
        )
    }

    private static func resolveFromAccessibility(
        highlightContext: FocusHighlightContext
    ) -> CuseHighlightSourceResolution? {
        guard let windowContext = highlightContext.hoveredWindow else { return nil }
        let candidatePoints = sampledPoints(context: highlightContext)

        for point in candidatePoints {
            guard let element = elementAt(appKitPointToCoreGraphicsPoint(point)) else { continue }
            var elementProcessIdentifier: pid_t = 0
            AXUIElementGetPid(element, &elementProcessIdentifier)
            guard elementProcessIdentifier == windowContext.processIdentifier else { continue }
            if let resolution = resolutionFromAttributes(
                element: element,
                source: "accessibility.element",
                appContext: windowContext,
                highlightContext: highlightContext,
                confidence: 0.9
            ) {
                return resolution
            }
        }

        let axApp = AXUIElementCreateApplication(windowContext.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.2)

        var focusedElementRef: AnyObject?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedElementRef) == .success,
           let focusedElementRef,
           let resolution = resolutionFromAttributes(
            element: focusedElementRef as! AXUIElement,
            source: "accessibility.focused_element",
            appContext: windowContext,
            highlightContext: highlightContext,
            confidence: 0.75
           ) {
            return resolution
        }

        var focusedWindowRef: AnyObject?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindowRef) == .success,
           let focusedWindowRef {
            let focusedWindow = focusedWindowRef as! AXUIElement
            if let resolution = resolutionFromAttributes(
                element: focusedWindow,
                source: "accessibility.focused_window",
                appContext: windowContext,
                highlightContext: highlightContext,
                confidence: 0.7
            ) {
                return resolution
            }
            return searchDescendantsForSource(
                root: focusedWindow,
                appContext: windowContext,
                highlightContext: highlightContext
            )
        }

        return nil
    }

    private static func searchDescendantsForSource(
        root: AXUIElement,
        appContext: FocusHighlightWindowContext,
        highlightContext: FocusHighlightContext
    ) -> CuseHighlightSourceResolution? {
        var visitedCount = 0
        func walk(_ element: AXUIElement, depth: Int) -> CuseHighlightSourceResolution? {
            guard depth <= 3, visitedCount < 80 else { return nil }
            visitedCount += 1
            if let resolution = resolutionFromAttributes(
                element: element,
                source: "accessibility.descendant",
                appContext: appContext,
                highlightContext: highlightContext,
                confidence: 0.6
            ) {
                return resolution
            }

            var childrenRef: AnyObject?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement] else {
                return nil
            }
            for child in children {
                if let resolution = walk(child, depth: depth + 1) {
                    return resolution
                }
            }
            return nil
        }
        return walk(root, depth: 0)
    }

    private static func resolutionFromAttributes(
        element: AXUIElement,
        source: String,
        appContext: FocusHighlightWindowContext,
        highlightContext: FocusHighlightContext,
        confidence: Double
    ) -> CuseHighlightSourceResolution? {
        let attributes = ["AXURL", "AXDocument", "AXFilename"]
        for attribute in attributes {
            var valueRef: AnyObject?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef) == .success,
                  let valueRef else {
                continue
            }
            if let resolution = resolutionForAttributeValue(
                valueRef,
                source: "\(source).\(attribute)",
                appContext: appContext,
                highlightContext: highlightContext,
                confidence: confidence
            ) {
                return resolution
            }
        }
        return nil
    }

    private static func resolutionForAttributeValue(
        _ value: AnyObject,
        source: String,
        appContext: FocusHighlightWindowContext,
        highlightContext: FocusHighlightContext,
        confidence: Double
    ) -> CuseHighlightSourceResolution? {
        if let url = value as? URL {
            return resolutionForURL(
                url,
                source: source,
                appContext: appContext,
                highlightContext: highlightContext,
                confidence: confidence
            )
        }
        if let string = value as? String {
            if let url = URL(string: string), url.scheme != nil {
                return resolutionForURL(
                    url,
                    source: source,
                    appContext: appContext,
                    highlightContext: highlightContext,
                    confidence: confidence
                )
            }
            return resolutionForLocalFile(
                path: string,
                source: source,
                appContext: appContext,
                highlightContext: highlightContext,
                confidence: confidence
            )
        }
        return nil
    }

    private static func windowContext(for application: NSRunningApplication?) -> FocusHighlightWindowContext? {
        guard let application,
              application.processIdentifier > 0,
              application.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return nil
        }
        return FocusHighlightWindowContext(
            windowID: nil,
            appName: application.localizedName ?? application.bundleIdentifier ?? "Unknown",
            bundleIdentifier: application.bundleIdentifier,
            processIdentifier: application.processIdentifier,
            windowTitle: nil,
            globalAppKitFrame: .zero
        )
    }

    private static func resolveFromAppleScript(
        windowContext: FocusHighlightWindowContext?,
        highlightContext: FocusHighlightContext
    ) -> CuseHighlightSourceResolution? {
        guard let windowContext else { return nil }
        switch windowContext.bundleIdentifier {
        case "com.apple.Preview":
            let script = """
            tell application "Preview"
              if it is running and (count of documents) > 0 then
                POSIX path of (path of front document as alias)
              end if
            end tell
            """
            return runAppleScript(script).flatMap {
                resolutionForLocalFile(
                    path: $0,
                    source: "applescript.preview.front_document",
                    appContext: windowContext,
                    highlightContext: highlightContext,
                    confidence: 0.95
                )
            }
        case "com.apple.TextEdit":
            let script = """
            tell application "TextEdit"
              if it is running and (count of documents) > 0 then
                POSIX path of (path of front document as alias)
              end if
            end tell
            """
            return runAppleScript(script).flatMap {
                resolutionForLocalFile(
                    path: $0,
                    source: "applescript.textedit.front_document",
                    appContext: windowContext,
                    highlightContext: highlightContext,
                    confidence: 0.95
                )
            }
        case "com.apple.finder":
            let script = """
            tell application "Finder"
              if (count of selection) > 0 then
                POSIX path of ((item 1 of selection) as alias)
              end if
            end tell
            """
            return runAppleScript(script).flatMap {
                resolutionForLocalFile(
                    path: $0,
                    source: "applescript.finder.selection",
                    appContext: windowContext,
                    highlightContext: highlightContext,
                    confidence: 0.8
                )
            }
        default:
            return nil
        }
    }

    private static func resolveBrowserURL(
        windowContext: FocusHighlightWindowContext?,
        highlightContext: FocusHighlightContext
    ) -> CuseHighlightSourceResolution? {
        guard let windowContext else { return nil }
        let script: String
        switch windowContext.bundleIdentifier {
        case "com.apple.Safari":
            script = """
            tell application "Safari"
              if it is running and (count of windows) > 0 then URL of current tab of front window
            end tell
            """
        case "com.google.Chrome":
            script = """
            tell application "Google Chrome"
              if it is running and (count of windows) > 0 then URL of active tab of front window
            end tell
            """
        default:
            return nil
        }

        guard let urlString = runAppleScript(script),
              let url = URL(string: urlString),
              let scheme = url.scheme,
              ["http", "https", "file"].contains(scheme.lowercased()) else {
            return nil
        }
        return resolutionForURL(
            url,
            source: "applescript.browser.active_tab",
            appContext: windowContext,
            highlightContext: highlightContext,
            confidence: scheme.lowercased() == "file" ? 0.75 : 0.45
        )
    }

    private static func resolutionForURL(
        _ url: URL,
        source: String,
        appContext: FocusHighlightWindowContext,
        highlightContext: FocusHighlightContext,
        confidence: Double
    ) -> CuseHighlightSourceResolution? {
        if url.isFileURL {
            return resolutionForLocalFile(
                path: url.path,
                source: source,
                appContext: appContext,
                highlightContext: highlightContext,
                confidence: confidence
            )
        }

        let kind = imageExtensions.contains(url.pathExtension.lowercased())
            ? "remote_image_url"
            : "remote_page_url"
        return enrichedResolution(
            ok: true,
            kind: kind,
            source: source,
            filePath: nil,
            sourceURL: url.absoluteString,
            appContext: appContext,
            highlightContext: highlightContext,
            confidence: confidence,
            reason: nil,
            message: "Resolved a browser URL. The outer agent can inspect or download it if needed."
        )
    }

    private static func resolutionForLocalFile(
        path rawPath: String,
        source: String,
        appContext: FocusHighlightWindowContext?,
        highlightContext: FocusHighlightContext?,
        confidence: Double
    ) -> CuseHighlightSourceResolution? {
        let expandedPath = (rawPath as NSString).expandingTildeInPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expandedPath.isEmpty else { return nil }
        let url = URL(fileURLWithPath: expandedPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return enrichedResolution(
            ok: true,
            kind: "local_file",
            source: source,
            filePath: url.path,
            sourceURL: url.absoluteString,
            appContext: appContext,
            highlightContext: highlightContext,
            confidence: confidence,
            reason: nil,
            message: "Resolved the local file for the highlighted context."
        )
    }

    private static func enrichedResolution(
        ok: Bool,
        kind: String,
        source: String,
        filePath: String?,
        sourceURL: String?,
        appContext: FocusHighlightWindowContext?,
        highlightContext: FocusHighlightContext?,
        confidence: Double,
        reason: String?,
        message: String?
    ) -> CuseHighlightSourceResolution {
        let fileExtension = filePath
            .map { URL(fileURLWithPath: $0).pathExtension.lowercased() }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? sourceURL
                .flatMap(URL.init(string:))?
                .pathExtension
                .lowercased()
        let contentCategory = contentCategoryFor(
            fileExtension: fileExtension,
            sourceURL: sourceURL,
            kind: kind
        )
        let mimeType = mimeTypeFor(fileExtension: fileExtension, contentCategory: contentCategory)
        let selectedText = highlightContext?.textSelection?.selectedText
        let highlightRect = highlightContext.map { context in
            let rect = context.globalAppKitBoundingRect
            return [rect.minX, rect.minY, rect.width, rect.height].map(Double.init)
        }

        return CuseHighlightSourceResolution(
            ok: ok,
            kind: kind,
            source: source,
            filePath: filePath,
            sourceURL: sourceURL,
            appName: appContext?.appName,
            bundleIdentifier: appContext?.bundleIdentifier,
            processIdentifier: appContext.map { Int($0.processIdentifier) },
            windowTitle: appContext?.windowTitle,
            confidence: confidence,
            reason: reason,
            message: message,
            contentCategory: contentCategory,
            fileExtension: fileExtension,
            mimeType: mimeType,
            selectedText: selectedText,
            highlightScreenRect: highlightRect,
            tools: toolCapabilities(
                kind: kind,
                contentCategory: contentCategory,
                filePath: filePath,
                sourceURL: sourceURL,
                selectedText: selectedText
            )
        )
    }

    private static func toolCapabilities(
        kind: String,
        contentCategory: String,
        filePath: String?,
        sourceURL: String?,
        selectedText: String?
    ) -> [CuseHighlightToolCapability] {
        var tools: [CuseHighlightToolCapability] = [
            CuseHighlightToolCapability(
                id: "visual_context",
                title: "Get visual context",
                endpoint: "/v1/visual-context",
                mode: "observe",
                reason: "Always useful for highlighted screen regions."
            )
        ]

        if filePath != nil || sourceURL != nil {
            tools.append(
                CuseHighlightToolCapability(
                    id: "open_source",
                    title: "Open source",
                    endpoint: "/v1/workflow-plan",
                    mode: "action",
                    reason: "The highlighted context resolved to a file or URL."
                )
            )
        }

        switch contentCategory {
        case "text", "code", "markdown", "json":
            tools.append(
                CuseHighlightToolCapability(
                    id: "text_edit",
                    title: "Edit text",
                    endpoint: nil,
                    mode: "agent_file_tool",
                    reason: "Text-like files should be edited by the outer agent using file tools, then verified through Cuse if needed."
                )
            )
        case "pdf":
            tools.append(
                CuseHighlightToolCapability(
                    id: "document_extract",
                    title: "Extract document text",
                    endpoint: nil,
                    mode: "agent_file_tool",
                    reason: "PDFs need document parsing or visual context before editing."
                )
            )
        default:
            break
        }

        if selectedText?.isEmpty == false {
            tools.append(
                CuseHighlightToolCapability(
                    id: "selected_text_edit",
                    title: "Edit selected text",
                    endpoint: "/v1/workflow-plan",
                    mode: "action",
                    reason: "Cuse captured an active text selection or painted text range."
                )
            )
        }

        if kind == "screenshot_only" {
            tools.append(
                CuseHighlightToolCapability(
                    id: "screenshot_crop",
                    title: "Use screenshot crop",
                    endpoint: "/v1/visual-context",
                    mode: "observe",
                    reason: "No source file was resolved, so screenshot/crop context is the reliable fallback."
                )
            )
        }

        return tools
    }

    private static func contentCategoryFor(
        fileExtension: String?,
        sourceURL: String?,
        kind: String
    ) -> String {
        guard let fileExtension, !fileExtension.isEmpty else {
            if kind == "remote_page_url" { return "web" }
            return kind == "screenshot_only" ? "visual" : "unknown"
        }
        if imageExtensions.contains(fileExtension) { return "image" }
        if codeExtensions.contains(fileExtension) { return "code" }
        if markdownExtensions.contains(fileExtension) { return "markdown" }
        if jsonExtensions.contains(fileExtension) { return "json" }
        if textExtensions.contains(fileExtension) { return "text" }
        if fileExtension == "pdf" { return "pdf" }
        return sourceURL != nil && kind == "remote_page_url" ? "web" : "file"
    }

    private static func mimeTypeFor(fileExtension: String?, contentCategory: String) -> String? {
        guard let fileExtension else {
            return contentCategory == "text" ? "text/plain" : nil
        }
        switch fileExtension {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "webp": return "image/webp"
        case "avif": return "image/avif"
        case "tif", "tiff": return "image/tiff"
        case "gif": return "image/gif"
        case "bmp": return "image/bmp"
        case "pdf": return "application/pdf"
        case "json": return "application/json"
        case "md", "markdown": return "text/markdown"
        case "html", "htm": return "text/html"
        case "csv": return "text/csv"
        default:
            return ["text", "code", "markdown"].contains(contentCategory) ? "text/plain" : nil
        }
    }

    private static func runAppleScript(_ script: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return output?.isEmpty == false ? output : nil
        } catch {
            return nil
        }
    }

    private static func sampledPoints(context: FocusHighlightContext) -> [CGPoint] {
        var points: [CGPoint] = []
        points.append(context.center)
        points.append(contentsOf: context.globalAppKitPoints.suffix(8))
        let rect = context.globalAppKitBoundingRect
        points.append(CGPoint(x: rect.midX, y: rect.midY))
        points.append(CGPoint(x: rect.minX + rect.width * 0.25, y: rect.midY))
        points.append(CGPoint(x: rect.minX + rect.width * 0.75, y: rect.midY))

        var seen = Set<String>()
        return points.filter { point in
            let key = "\(Int(point.x)):\(Int(point.y))"
            return seen.insert(key).inserted
        }
    }

    private static func appKitPointToCoreGraphicsPoint(_ point: CGPoint) -> CGPoint {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else {
            return point
        }
        return CGPoint(
            x: point.x,
            y: screen.frame.maxY - point.y + screen.frame.minY
        )
    }

    private static func elementAt(_ coreGraphicsPoint: CGPoint) -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWideElement, 0.2)
        var elementRef: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(coreGraphicsPoint.x),
            Float(coreGraphicsPoint.y),
            &elementRef
        )
        guard result == .success else { return nil }
        return elementRef
    }

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "avif", "tif", "tiff", "gif", "bmp"
    ]

    private static let textExtensions: Set<String> = [
        "txt", "text", "rtf", "log", "csv", "tsv", "yaml", "yml", "toml", "ini", "env"
    ]

    private static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdx"
    ]

    private static let jsonExtensions: Set<String> = [
        "json", "jsonl"
    ]

    private static let codeExtensions: Set<String> = [
        "swift", "py", "js", "jsx", "ts", "tsx", "html", "css", "scss", "java", "kt", "go",
        "rs", "rb", "php", "c", "h", "cpp", "hpp", "m", "mm", "sh", "zsh", "bash", "sql"
    ]
}
