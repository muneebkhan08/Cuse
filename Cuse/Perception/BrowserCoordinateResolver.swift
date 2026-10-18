//
//  BrowserCoordinateResolver.swift
//  Cuse
//
//  Browser-page coordinate fallback for Chrome/Chromium targets.
//  Uses CUA's CDP client when a debugging port is available, then maps
//  the matched DOM element's viewport rect into Cuse's global AppKit
//  coordinate space.
//

import AppKit
import CoreGraphics
import CuaDriverCore
import Foundation

final class BrowserCoordinateResolver: @unchecked Sendable {

    struct BrowserResolution {
        let globalScreenPoint: CGPoint
        let globalScreenRect: CGRect
        let matchedLabel: String
    }

    private struct DOMMatch: Decodable {
        let label: String
        let screenX: Double
        let screenY: Double
        let width: Double
        let height: Double
        let score: Double
    }

    private let cdpCandidatePorts = [9222, 9223, 9224, 9225, 9230]

    func resolve(label: String, targetAppHint: String?) async -> BrowserResolution? {
        guard isBrowserTarget(targetAppHint: targetAppHint) else { return nil }

        guard let port = await CDPClient.findPageTarget(ports: cdpCandidatePorts) else {
            print("[BrowserResolver] no CDP page target available for \"\(label)\"")
            return nil
        }

        do {
            let result = try await CDPClient.evaluate(
                javascript: Self.domMatchJavaScript(for: label),
                port: port
            )
            guard let data = result.data(using: .utf8),
                  let match = try? JSONDecoder().decode(DOMMatch.self, from: data),
                  match.score > 0 else {
                print("[BrowserResolver] CDP found no DOM match for \"\(label)\"")
                return nil
            }

            let globalScreenRect = topLeftScreenRectToAppKitRect(
                x: CGFloat(match.screenX),
                y: CGFloat(match.screenY),
                width: CGFloat(match.width),
                height: CGFloat(match.height)
            )
            guard globalScreenRect.width > 0, globalScreenRect.height > 0 else {
                return nil
            }

            let resolution = BrowserResolution(
                globalScreenPoint: CGPoint(
                    x: globalScreenRect.midX,
                    y: globalScreenRect.midY
                ),
                globalScreenRect: globalScreenRect,
                matchedLabel: match.label
            )
            print("[BrowserResolver] ✓ CDP matched \"\(label)\" → \"\(match.label)\" at \(resolution.globalScreenPoint)")
            return resolution
        } catch {
            print("[BrowserResolver] CDP failed for \"\(label)\": \(error.localizedDescription)")
            return nil
        }
    }

    private func isBrowserTarget(targetAppHint: String?) -> Bool {
        let hint = (targetAppHint ?? AccessibilityTreeResolver.userTargetAppOverride?.localizedName ?? "")
            .lowercased()
        guard !hint.isEmpty else {
            let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            return Self.chromiumBrowserBundleIdentifiers.contains(bundleIdentifier)
        }

        return hint.contains("chrome")
            || hint.contains("chromium")
            || hint.contains("brave")
            || hint.contains("edge")
            || hint.contains("arc")
            || hint.contains("browser")
            || hint.contains("google docs")
            || hint.contains("google sheets")
            || hint.contains("google slides")
    }

    private static let chromiumBrowserBundleIdentifiers: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser"
    ]

    private func topLeftScreenRectToAppKitRect(
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> CGRect {
        let primaryScreen = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let primaryScreen else {
            return CGRect(x: x, y: y, width: width, height: height)
        }

        return CGRect(
            x: x,
            y: primaryScreen.frame.height - y - height,
            width: width,
            height: height
        )
    }

    private static func domMatchJavaScript(for label: String) -> String {
        let encodedLabel = String(
            data: try! JSONEncoder().encode(label),
            encoding: .utf8
        ) ?? "\"\""

        return """
        (() => {
          const query = \(encodedLabel);
          const normalize = (value) => String(value || "")
            .toLowerCase()
            .replace(/[\\u2026]/g, "...")
            .replace(/[^\\p{L}\\p{N}]+/gu, " ")
            .trim();
          const queryNormalized = normalize(query);
          const queryWords = new Set(queryNormalized.split(/\\s+/).filter(Boolean));
          const visible = (element, rect) => {
            const style = window.getComputedStyle(element);
            return rect.width > 2
              && rect.height > 2
              && style.visibility !== "hidden"
              && style.display !== "none"
              && Number(style.opacity || "1") > 0.02;
          };
          const textFor = (element) => [
            element.getAttribute("aria-label"),
            element.getAttribute("title"),
            element.getAttribute("alt"),
            element.getAttribute("placeholder"),
            element.innerText,
            element.textContent,
            element.value
          ].filter(Boolean).join(" ");
          const score = (text, element) => {
            const normalizedText = normalize(text);
            if (!normalizedText || !queryNormalized) return 0;
            if (normalizedText === queryNormalized) return 100;
            if (normalizedText.includes(queryNormalized)) return 82;
            if (queryNormalized.includes(normalizedText) && normalizedText.length >= 3) return 72;
            const textWords = new Set(normalizedText.split(/\\s+/).filter(Boolean));
            let overlap = 0;
            for (const word of queryWords) {
              if (textWords.has(word)) overlap += 1;
            }
            let base = overlap > 0 ? 40 + overlap * 12 : 0;
            const role = String(element.getAttribute("role") || "").toLowerCase();
            const tag = element.tagName.toLowerCase();
            if (["button", "a", "input", "textarea", "select", "summary"].includes(tag)) base += 8;
            if (["button", "link", "menuitem", "tab", "textbox"].includes(role)) base += 8;
            return base;
          };
          const selectors = [
            "button", "a", "input", "textarea", "select", "summary",
            "[role='button']", "[role='link']", "[role='menuitem']",
            "[role='tab']", "[role='textbox']", "[aria-label]",
            "[title]", "[placeholder]", "[contenteditable='true']",
            "[tabindex]"
          ];
          const candidates = Array.from(new Set(document.querySelectorAll(selectors.join(","))));
          let best = null;
          for (const element of candidates) {
            const rect = element.getBoundingClientRect();
            if (!visible(element, rect)) continue;
            const labelText = textFor(element);
            const candidateScore = score(labelText, element);
            if (candidateScore <= 0) continue;
            if (!best || candidateScore > best.score) {
              const browserLeftBorder = Math.max(0, (window.outerWidth - window.innerWidth) / 2);
              const browserTopChrome = Math.max(0, window.outerHeight - window.innerHeight - browserLeftBorder);
              best = {
                label: labelText.replace(/\\s+/g, " ").trim().slice(0, 120),
                screenX: window.screenX + browserLeftBorder + rect.left,
                screenY: window.screenY + browserTopChrome + rect.top,
                width: rect.width,
                height: rect.height,
                score: candidateScore
              };
            }
          }
          return best ? JSON.stringify(best) : "null";
        })()
        """
    }
}
