import SwiftUI
import UIKit

/// Select once after the native field acquires focus. SwiftUI text selection
/// can be overwritten by first-responder acquisition during the overlay's entry.
struct MobileAddressField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let entryID: UUID
    let submit: () -> Void
    let moveSuggestion: (Int) -> Void
    let dismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> AddressTextField {
        let field = AddressTextField()
        field.placeholder = String(localized: "Search or enter address")
        field.accessibilityLabel = field.placeholder
        field.accessibilityIdentifier = "browser.omnibar"
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.keyboardType = .webSearch
        field.returnKeyType = .go
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: AddressTextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        field.moveSuggestion = moveSuggestion
        field.dismissAddress = dismiss
        field.wantsFocus = isFocused
        if isFocused, field.window != nil, !field.isFirstResponder { field.becomeFirstResponder() }
        if !isFocused, field.isFirstResponder { field.resignFirstResponder() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: AddressTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: max(44, (uiView.font?.lineHeight ?? 20) + 12))
    }

    @MainActor final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: MobileAddressField
        private var selectedEntry: UUID?
        private var editedEntry: UUID?
        init(_ parent: MobileAddressField) { self.parent = parent }

        @objc func changed(_ field: UITextField) {
            editedEntry = parent.entryID
            parent.text = field.text ?? ""
        }

        func textFieldDidBeginEditing(_ field: UITextField) {
            parent.isFocused = true
            let entry = parent.entryID
            guard selectedEntry != entry else { return }
            selectedEntry = entry
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field, field.isFirstResponder,
                      self.parent.entryID == entry, self.editedEntry != entry else { return }
                field.selectAll(nil)
            }
        }

        func textFieldDidEndEditing(_ field: UITextField) { parent.isFocused = false }
        func textFieldShouldReturn(_ field: UITextField) -> Bool { parent.submit(); return false }
    }
}

final class AddressTextField: UITextField {
    var wantsFocus = false
    var moveSuggestion: ((Int) -> Void)?
    var dismissAddress: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, wantsFocus { becomeFirstResponder() }
    }

    override var keyCommands: [UIKeyCommand]? {
        let commands = [
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(nextSuggestion)),
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(previousSuggestion)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closeAddress))
        ]
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return commands
    }
    @objc private func nextSuggestion() { moveSuggestion?(1) }
    @objc private func previousSuggestion() { moveSuggestion?(-1) }
    @objc private func closeAddress() { dismissAddress?() }
}
