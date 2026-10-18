//
//  FocusHighlightContext.swift
//  Cuse
//
//  Spatial context painted by the user with the highlight hotkey.
//  This is not normal text selection; it is an attention region that
//  tells Gemini what "this area" means.
//

import CoreGraphics
import Foundation

struct FocusHighlightWindowContext: Equatable {
    let windowID: Int?
    let appName: String
    let bundleIdentifier: String?
    let processIdentifier: pid_t
    let windowTitle: String?
    let globalAppKitFrame: CGRect
}

struct FocusHighlightElementContext: Equatable {
    let role: String?
    let title: String?
    let value: String?
    let description: String?
    let globalAppKitFrame: CGRect?
}

struct FocusHighlightTextSelectionContext: Equatable {
    let selectedText: String
    let focusedElementRole: String?
    let selectedTextRangeLocation: Int?
    let selectedTextRangeLength: Int?
    let source: String
}

struct FocusHighlightContext: Equatable {
    let id: UUID
    let createdAt: Date
    let globalAppKitPoints: [CGPoint]
    let globalAppKitBoundingRect: CGRect
    let hoveredWindow: FocusHighlightWindowContext?
    let intersectedElement: FocusHighlightElementContext?
    let textSelection: FocusHighlightTextSelectionContext?

    var center: CGPoint {
        CGPoint(
            x: globalAppKitBoundingRect.midX,
            y: globalAppKitBoundingRect.midY
        )
    }

    init?(
        points: [CGPoint],
        hoveredWindow: FocusHighlightWindowContext?,
        intersectedElement: FocusHighlightElementContext?,
        textSelection: FocusHighlightTextSelectionContext?
    ) {
        guard points.count >= 2 else { return nil }

        let boundingRect = points.reduce(CGRect.null) { partialRect, point in
            partialRect.union(CGRect(origin: point, size: .zero))
        }.insetBy(dx: -12, dy: -12)

        guard !boundingRect.isNull, boundingRect.width > 4, boundingRect.height > 4 else {
            return nil
        }

        self.id = UUID()
        self.createdAt = Date()
        self.globalAppKitPoints = points
        self.globalAppKitBoundingRect = boundingRect
        self.hoveredWindow = hoveredWindow
        self.intersectedElement = intersectedElement
        self.textSelection = textSelection
    }
}
