import Foundation
import CoreGraphics
import Testing
@testable import Browser

struct AutofillFocusSignalTests {
    /// The literal dictionary the page runtime posts.
    private func payload(
        documentToken: String = "6C4F1B62-1E2F-4C4A-9E5B-0A1B2C3D4E5F",
        localID: String = "semantic-doc-7",
        overrides: [String: Any] = [:],
        removing: [String] = []
    ) -> [String: Any] {
        var body: [String: Any] = [
            "type": "autofillFieldFocused",
            "documentToken": documentToken,
            "localID": localID,
            "role": "input",
            "name": "Email",
            "geometryDigest": "10:20:200:30",
            "frameContext": [],
            "hints": [
                "tag": "input",
                "type": "email",
                "autocomplete": "email",
                "name": "email",
                "elementID": "email-field",
                "placeholder": "you@example.com",
                "label": "Email address",
                "ariaLabel": "",
                "isVisible": true,
                "isEditable": true,
                "isEmpty": true,
            ],
            "rect": ["x": 10, "y": 20, "width": 200, "height": 30],
        ]
        for (key, value) in overrides { body[key] = value }
        for key in removing { body.removeValue(forKey: key) }
        return body
    }

    @Test func decodesAWellFormedSignal() throws {
        let signal = try AutofillFocusSignal.decode(payload())
        #expect(signal.localID == "semantic-doc-7")
        #expect(signal.role == "input")
        #expect(signal.rect == CGRect(x: 10, y: 20, width: 200, height: 30))
        #expect(signal.hints.autocomplete == "email")
        #expect(signal.hints.label == "Email address")
        #expect(signal.hints.isEmpty)
        // And it classifies, which is the whole point of carrying the hints.
        #expect(AutofillFieldClassifier.classify(signal.hints) == .email)
    }

    @Test func missingRequiredKeysThrow() {
        for key in ["documentToken", "localID", "geometryDigest", "hints", "rect"] {
            #expect(throws: (any Error).self) {
                try AutofillFocusSignal.decode(payload(removing: [key]))
            }
        }
    }

    @Test func malformedValuesThrow() {
        #expect(throws: (any Error).self) {
            try AutofillFocusSignal.decode(payload(overrides: ["rect": ["x": 1, "y": 2]]))
        }
        #expect(throws: (any Error).self) {
            try AutofillFocusSignal.decode(payload(overrides: ["rect": "not a rect"]))
        }
        #expect(throws: (any Error).self) {
            try AutofillFocusSignal.decode(payload(overrides: ["documentToken": ""]))
        }
        #expect(throws: (any Error).self) {
            try AutofillFocusSignal.decode(payload(overrides: ["hints": ["tag": 42]]))
        }
        #expect(throws: (any Error).self) {
            try AutofillFocusSignal.decode("nonsense")
        }
    }

    @Test func effectReferenceMatchesWhatResolveExpects() throws {
        let signal = try AutofillFocusSignal.decode(payload())
        let reference = signal.effectReference

        // The five fields resolve() compares, plus the document token.
        #expect(Set(reference.keys) == [
            "documentToken", "localID", "role", "name", "geometryDigest", "frameContext",
        ])
        #expect(reference["localID"] as? String == "semantic-doc-7")
        #expect(reference["role"] as? String == "input")
        #expect(reference["name"] as? String == "Email")
        #expect(reference["geometryDigest"] as? String == "10:20:200:30")
        #expect((reference["frameContext"] as? [Any])?.isEmpty == true)
        // It has to survive the trip to JavaScript.
        #expect(JSONSerialization.isValidJSONObject(reference))
    }
}

struct AutofillPageScanTests {
    private func node(
        localID: String,
        hints: [String: Any]?,
        frameContext: [Any] = []
    ) -> [String: Any] {
        var node: [String: Any] = [
            "localID": localID,
            "role": "input",
            "name": "Field",
            "geometryDigest": "0:0:100:20",
            "frameContext": frameContext,
        ]
        node["fieldHints"] = hints ?? NSNull()
        return node
    }

    private let emailHints: [String: Any] = [
        "tag": "input", "type": "text", "autocomplete": "email", "name": "email",
        "elementID": "", "placeholder": "", "label": "", "ariaLabel": "",
        "isVisible": true, "isEditable": true, "isEmpty": true,
    ]

    @Test func keepsOnlyFormControls() throws {
        let scan = try AutofillPageScan.decode([
            "documentToken": "abc",
            "nodes": [
                node(localID: "a", hints: emailHints),
                node(localID: "link", hints: nil),        // an <a>, no hints
            ],
        ])
        #expect(scan.documentToken == "abc")
        #expect(scan.fields.map(\.localID) == ["a"])
        #expect(scan.candidates.first?.descriptor.autocomplete == "email")
    }

    @Test func dropsAnythingInsideAFrame() throws {
        // The runtime is main-frame-only; a framed node means something
        // unexpected, and we don't write into it.
        let scan = try AutofillPageScan.decode([
            "documentToken": "abc",
            "nodes": [node(localID: "framed", hints: emailHints, frameContext: [["index": 0]])],
        ])
        #expect(scan.fields.isEmpty)
    }

    @Test func rejectsAMalformedPayload() {
        #expect(throws: (any Error).self) { try AutofillPageScan.decode(["nodes": []]) }
        #expect(throws: (any Error).self) { try AutofillPageScan.decode(["documentToken": "abc"]) }
        #expect(throws: (any Error).self) { try AutofillPageScan.decode(["documentToken": "", "nodes": []]) }
        #expect(throws: (any Error).self) { try AutofillPageScan.decode("nope") }
    }

    @Test func referencesMatchTheResolveContract() throws {
        let scan = try AutofillPageScan.decode([
            "documentToken": "tok",
            "nodes": [node(localID: "a", hints: emailHints)],
        ])
        let reference = try #require(scan.fields.first).reference(documentToken: scan.documentToken)
        #expect(Set(reference.keys) == [
            "documentToken", "localID", "role", "name", "geometryDigest", "frameContext",
        ])
        #expect(reference["documentToken"] as? String == "tok")
        #expect(JSONSerialization.isValidJSONObject(reference))
    }
}

struct AutofillKeyActionTests {
    @Test func theKeyTableCoversNavigationCommitAndEscape() {
        #expect(AutofillKeyAction.forKeyCode(125) == .move(1))    // ↓
        #expect(AutofillKeyAction.forKeyCode(126) == .move(-1))   // ↑
        #expect(AutofillKeyAction.forKeyCode(36) == .commit)      // Return
        #expect(AutofillKeyAction.forKeyCode(76) == .commit)      // Enter
        #expect(AutofillKeyAction.forKeyCode(53) == .dismiss(swallow: true))  // Escape
    }

    @Test func typingDismissesButStillReachesThePage() {
        // Letters, digits, Tab, Delete — the list gets out of the way rather
        // than eating the keystroke.
        for keyCode: UInt16 in [0, 1, 2, 18, 19, 48, 51, 49, 123, 124] {
            #expect(
                AutofillKeyAction.forKeyCode(keyCode) == .dismiss(swallow: false),
                "keyCode \(keyCode) must pass through"
            )
        }
    }
}

struct AutofillGeometryTests {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)

    @Test func unzoomedConversionOnlyFlipsY() {
        let css = CGRect(x: 100, y: 50, width: 200, height: 30)
        let rect = AutofillGeometry.viewRect(css: css, in: bounds, scale: 1)
        #expect(rect.minX == 100)
        #expect(rect.width == 200)
        #expect(rect.height == 30)
        // CSS top edge 50 from the top → AppKit bottom edge at 800 - 80.
        #expect(rect.minY == 720)
        #expect(rect.maxY == 750)
    }

    @Test func scaleAppliesToBothPositionAndSize() {
        let css = CGRect(x: 100, y: 50, width: 200, height: 30)
        let rect = AutofillGeometry.viewRect(css: css, in: bounds, scale: 2)
        #expect(rect.minX == 200)
        #expect(rect.width == 400)
        #expect(rect.height == 60)
        // Bottom edge: 800 - (50 + 30) * 2. Spelled as a CGFloat so the
        // expectation macro doesn't type the arithmetic as Int.
        let expectedMinY: CGFloat = 640
        #expect(rect.minY == expectedMinY)
    }

    @Test func aFieldAtTheViewportTopLandsAtTheViewTop() {
        let rect = AutofillGeometry.viewRect(
            css: CGRect(x: 0, y: 0, width: 100, height: 20),
            in: bounds,
            scale: 1
        )
        #expect(rect.maxY == bounds.height)
    }

    @Test func degenerateScaleIsClamped() {
        // A zero scale would collapse the rect and divide badly downstream.
        let rect = AutofillGeometry.viewRect(
            css: CGRect(x: 10, y: 10, width: 100, height: 20),
            in: bounds,
            scale: 0
        )
        #expect(rect.width > 0)
    }

    @Test func theListSitsBelowTheFieldWhenThereIsRoom() {
        // AppKit coords: the field's minY is its BOTTOM edge, so "below the
        // field" means a smaller y.
        let field = CGRect(x: 120, y: 500, width: 200, height: 30)
        let origin = AutofillGeometry.listOrigin(
            fieldRect: field,
            listSize: CGSize(width: 220, height: 90),
            windowHeight: 800
        )
        #expect(origin.x == 120)
        let expectedY: CGFloat = 500 - 4 - 90
        #expect(origin.y == expectedY)
    }

    @Test func theListFlipsAboveWhenItWouldFallOffTheBottom() {
        let field = CGRect(x: 10, y: 40, width: 200, height: 30)
        let origin = AutofillGeometry.listOrigin(
            fieldRect: field,
            listSize: CGSize(width: 220, height: 90),
            windowHeight: 800
        )
        #expect(origin.y == field.maxY + 4)
    }

    @Test func aFieldSqueezedAtBothEndsStaysBelow() {
        // Nowhere fits: prefer below rather than pushing the list off the top.
        let field = CGRect(x: 10, y: 40, width: 200, height: 30)
        let origin = AutofillGeometry.listOrigin(
            fieldRect: field,
            listSize: CGSize(width: 220, height: 700),
            windowHeight: 720
        )
        let expectedY: CGFloat = 40 - 4 - 700
        #expect(origin.y == expectedY)
    }
}
