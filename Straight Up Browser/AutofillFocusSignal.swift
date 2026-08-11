//
//  AutofillFocusSignal.swift
//  Straight Up Browser
//
//  What the page runtime reports when a fillable field takes focus, and the
//  arithmetic that turns its CSS rect into a place on screen.
//
//  Both halves are pure so they can be tested without a WKWebView: the decoder
//  against the literal dictionary JavaScript posts, the geometry as plain
//  coordinate maths.
//

import Foundation
import CoreGraphics

nonisolated struct AutofillFocusSignal: Equatable, Sendable {
    /// Identifies the document the element belongs to. Carried so a fill can be
    /// rejected if the page navigated between focus and pick.
    let documentToken: String
    let localID: String
    let role: String
    let name: String
    let geometryDigest: String
    let hints: AutofillFieldDescriptor
    /// CSS viewport pixels, main frame — the runtime is injected
    /// `forMainFrameOnly`, so there is no frame offset to unwind.
    let rect: CGRect

    /// The reference dictionary `resolve()` expects, matching
    /// `SemanticPageJavaScriptSnapshot.effectReference` field for field.
    var effectReference: [String: Any] {
        [
            "documentToken": documentToken,
            "localID": localID,
            "role": role,
            "name": name,
            "geometryDigest": geometryDigest,
            "frameContext": [] as [Any],
        ]
    }

    /// Decodes the raw `WKScriptMessage` body. Throws rather than defaulting:
    /// a malformed payload means the page is lying or the runtime changed, and
    /// either way there is nothing safe to show.
    static func decode(_ body: Any) throws -> AutofillFocusSignal {
        guard let dictionary = body as? [String: Any],
              let documentToken = dictionary["documentToken"] as? String, !documentToken.isEmpty,
              let localID = dictionary["localID"] as? String, !localID.isEmpty,
              let geometryDigest = dictionary["geometryDigest"] as? String,
              let rawHints = dictionary["hints"],
              let rawRect = dictionary["rect"] as? [String: Any],
              let x = (rawRect["x"] as? NSNumber)?.doubleValue,
              let y = (rawRect["y"] as? NSNumber)?.doubleValue,
              let width = (rawRect["width"] as? NSNumber)?.doubleValue,
              let height = (rawRect["height"] as? NSNumber)?.doubleValue,
              JSONSerialization.isValidJSONObject(rawHints),
              let data = try? JSONSerialization.data(withJSONObject: rawHints),
              let hints = try? JSONDecoder().decode(AutofillFieldDescriptor.self, from: data)
        else {
            throw SemanticPageJavaScriptError.invalidPayload
        }
        return AutofillFocusSignal(
            documentToken: documentToken,
            localID: localID,
            role: dictionary["role"] as? String ?? "",
            name: dictionary["name"] as? String ?? "",
            geometryDigest: geometryDigest,
            hints: hints,
            rect: CGRect(x: x, y: y, width: width, height: height)
        )
    }
}

/// One form control found in a page scan, with everything needed both to decide
/// what it wants and to write to it safely.
nonisolated struct AutofillFormField: Equatable, Sendable {
    let localID: String
    let role: String
    let name: String
    let geometryDigest: String
    let descriptor: AutofillFieldDescriptor

    var candidate: AutofillFieldCandidate {
        AutofillFieldCandidate(localID: localID, descriptor: descriptor)
    }

    /// Matches `SemanticPageJavaScriptSnapshot.effectReference` so the runtime's
    /// `resolve()` can re-verify the element hasn't been swapped underneath us.
    func reference(documentToken: String) -> [String: Any] {
        [
            "documentToken": documentToken,
            "localID": localID,
            "role": role,
            "name": name,
            "geometryDigest": geometryDigest,
            "frameContext": [] as [Any],
        ]
    }
}

/// The form controls on a page, decoded straight from the runtime's snapshot.
///
/// Deliberately a separate, minimal decode rather than going through
/// `SemanticPageJavaScriptSnapshot`: that path threads a navigation-generation
/// tracker owned by the agent's automation host, and autofill has no business
/// advancing it.
nonisolated struct AutofillPageScan: Equatable, Sendable {
    let documentToken: String
    let fields: [AutofillFormField]

    var candidates: [AutofillFieldCandidate] { fields.map(\.candidate) }

    static func decode(_ value: Any) throws -> AutofillPageScan {
        guard let root = value as? [String: Any],
              let documentToken = root["documentToken"] as? String, !documentToken.isEmpty,
              let nodes = root["nodes"] as? [[String: Any]]
        else { throw SemanticPageJavaScriptError.invalidPayload }

        let fields: [AutofillFormField] = nodes.compactMap { node in
            guard let localID = node["localID"] as? String,
                  let geometryDigest = node["geometryDigest"] as? String,
                  let rawHints = node["fieldHints"],
                  !(rawHints is NSNull),
                  JSONSerialization.isValidJSONObject(rawHints),
                  let data = try? JSONSerialization.data(withJSONObject: rawHints),
                  let descriptor = try? JSONDecoder().decode(AutofillFieldDescriptor.self, from: data)
            else { return nil }
            // Anything in a frame is out: the runtime is main-frame-only, so a
            // non-empty path means something unexpected produced this node.
            if let path = node["frameContext"] as? [Any], !path.isEmpty { return nil }
            return AutofillFormField(
                localID: localID,
                role: node["role"] as? String ?? "",
                name: node["name"] as? String ?? "",
                geometryDigest: geometryDigest,
                descriptor: descriptor
            )
        }
        return AutofillPageScan(documentToken: documentToken, fields: fields)
    }
}

/// What a keystroke means while the suggestion list is open. Pure, so the event
/// monitor's closure stays three lines of dispatch and this table gets tested.
nonisolated enum AutofillKeyAction: Equatable, Sendable {
    case move(Int)
    case commit
    /// `swallow: false` lets the keystroke through to the page — the user is
    /// typing, and the list simply gets out of the way.
    case dismiss(swallow: Bool)

    static func forKeyCode(_ keyCode: UInt16) -> AutofillKeyAction {
        switch keyCode {
        case 125: return .move(1)      // ↓
        case 126: return .move(-1)     // ↑
        case 36, 76: return .commit    // Return, Enter
        case 53: return .dismiss(swallow: true)   // Escape
        default: return .dismiss(swallow: false)
        }
    }
}

nonisolated enum AutofillGeometry {
    /// CSS viewport pixels → the web view's own (flipped, scaled) coordinates.
    ///
    /// Two conversions, both easy to get wrong:
    ///   * CSS counts y downward from the top; AppKit counts upward from the
    ///     bottom, so the rect is mirrored against the view height.
    ///   * A CSS pixel is only a point at 100%. Page zoom (⌘+) and pinch
    ///     magnification both scale it, and they multiply.
    ///
    /// ScreenshotManager does the same conversion but uses `magnification`
    /// alone; that is wrong on a ⌘+ zoomed page. Don't copy it back.
    static func viewRect(css: CGRect, in bounds: CGRect, scale: CGFloat) -> CGRect {
        let scale = max(scale, 0.01)
        return CGRect(
            x: css.minX * scale,
            y: bounds.height - (css.minY + css.height) * scale,
            width: css.width * scale,
            height: css.height * scale
        )
    }

    /// Where a suggestion list of `size` should sit for a field at `fieldRect`,
    /// both in AppKit window coordinates. Sits under the field, flipping above
    /// when there isn't room — the list lives inside the window, so the window's
    /// own bottom edge is the only one that can clip it.
    static func listOrigin(
        fieldRect: CGRect,
        listSize: CGSize,
        windowHeight: CGFloat,
        gap: CGFloat = 4
    ) -> CGPoint {
        let below = fieldRect.minY - gap - listSize.height
        let above = fieldRect.maxY + gap
        let y = below >= 0 || above + listSize.height > windowHeight ? below : above
        return CGPoint(x: fieldRect.minX, y: y)
    }
}
