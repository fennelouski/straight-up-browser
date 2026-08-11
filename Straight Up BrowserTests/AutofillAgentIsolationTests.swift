import Foundation
import Testing
@testable import Browser

/// Autofill extends the shared page runtime, which the agent also uses. These
/// pin the boundary: the agent must see exactly what it saw before, and must
/// never gain a route to the user's saved details.
struct AutofillAgentIsolationTests {
    private func node(
        localID: String,
        role: String,
        name: String,
        fieldHints: AutofillFieldDescriptor?
    ) -> SemanticNodeSnapshot {
        SemanticNodeSnapshot(
            localID: localID,
            legacySubID: 1,
            role: role,
            name: name,
            states: [.visible, .enabled, .editable],
            geometryDigest: SemanticGeometryDigest(rawValue: "0:0:100:20"),
            text: "",
            isInteractive: true,
            fieldHints: fieldHints
        )
    }

    private func rendered(with hints: AutofillFieldDescriptor?, enhanced: Bool) -> String {
        let snapshot = SemanticPageSnapshot(
            page: PageHandle(windowID: UUID(), tabID: UUID()),
            navigationGeneration: PageNavigationGeneration(rawValue: 1),
            documentGeneration: PageDocumentGeneration(rawValue: UUID()),
            nodes: [node(localID: "a", role: "input", name: "Email", fieldHints: hints)],
            inaccessibleFrameBoundaries: [],
            visibleText: "Sign up"
        )
        return SemanticPageJavaScriptSnapshot.renderCompatibilityText(
            SemanticPageJavaScriptSnapshot(
                snapshot: snapshot,
                url: URL(string: "https://example.com/signup"),
                title: "Sign up"
            ),
            enhanced: enhanced
        )
    }

    @Test func fieldHintsNeverReachTheAgentsSnapshotText() {
        let hints = AutofillFieldDescriptor(
            tag: "input",
            type: "email",
            autocomplete: "email",
            name: "user_email",
            elementID: "signup-email",
            placeholder: "you@example.com",
            label: "Email address"
        )
        // Byte-identical with and without the hints, in both renderings. Adding
        // them to the agent's context would change its behaviour and token cost;
        // that's a separate decision, not a side effect of autofill.
        for enhanced in [false, true] {
            #expect(rendered(with: hints, enhanced: enhanced) == rendered(with: nil, enhanced: enhanced))
        }

        let text = rendered(with: hints, enhanced: true)
        for leaked in ["user_email", "signup-email", "you@example.com", "autocomplete"] {
            #expect(!text.contains(leaked), "\(leaked) leaked into the agent snapshot")
        }
    }

    @Test func theRuntimeCollectsHintsOnlyForFormControls() {
        // The gate keeps scan()'s per-node cost off the other 4000 elements.
        #expect(SemanticPageJavaScript.bootstrap.contains("const FILLABLE_TAGS = /^(INPUT|TEXTAREA|SELECT)$/"))
        #expect(SemanticPageJavaScript.bootstrap.contains("FILLABLE_TAGS.test(element.tagName || '') ? fieldHints(element) : null"))
    }

    @Test func theIsolatedWorldHasItsOwnMessageHandlerName() {
        // Sharing "sub" would put the focus signal in the page's reach.
        #expect(SemanticPageJavaScript.messageHandlerName == "straightUpSemantic")
        #expect(SemanticPageJavaScript.messageHandlerName != "sub")
        #expect(SemanticPageJavaScript.bootstrap.contains("messageHandlers.straightUpSemantic"))
    }

    @Test func theFillLoopRefusesPasswordsAndSuppressesRefocus() {
        let bootstrap = SemanticPageJavaScript.bootstrap
        // A redundant guard inside the apply loop, in case a bad plan ever
        // reaches it.
        #expect(bootstrap.contains("if (element.type === 'password') continue;"))
        // setValue() focuses each field; without this the list reopens per field.
        #expect(bootstrap.contains("state.autofillSuppressed = true;"))
        #expect(bootstrap.contains("state.autofillSuppressed = false;"))
        // One scan for the whole batch, not one per field.
        #expect(bootstrap.contains("const autofillApply = request =>"))
    }

    @Test func passwordAndHiddenFieldsNeverEvenSignalFocus() {
        #expect(SemanticPageJavaScript.bootstrap.contains("if (type === 'password' || type === 'hidden') return;"))
    }
}
