#if os(macOS)
import SwiftUI

struct GlobalHotkeyChange {
    let before: String
    let after: String
    let revision: Int
}

@Observable final class GlobalHotkeyStatus {
    static let shared = GlobalHotkeyStatus()
    var state: GlobalHotkeyRegistrationState = .disabled
    var undo: GlobalHotkeyChange?
    var recoveryRequired = false

    static func title(_ chord: String) -> String {
        switch chord {
        case "optSpace": return "⌥Space"
        case "ctrlOptSpace": return "⌃⌥Space"
        default: return "Off"
        }
    }
}

struct GlobalOmnibarStatusView: View {
    @State private var message: String?
    private var status: GlobalHotkeyStatus { .shared }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if status.recoveryRequired {
                Text("The system couldn't release an extra registration. Both bindings may still respond. Retry to finish cleanup before choosing another shortcut.")
            }
            switch status.state {
            case .disabled:
                Text("Global shortcut is off.")
            case .registered(let chord):
                Text("\(GlobalHotkeyStatus.title(chord)) is registered by Browser.")
            case .failed(let chord, let code):
                Label {
                    Text(code == -9878
                         ? "\(GlobalHotkeyStatus.title(chord)) couldn't be registered because it is already in use."
                         : "\(GlobalHotkeyStatus.title(chord)) couldn't be enabled (system code \(code)).")
                } icon: { Image(systemName: "exclamationmark.triangle") }
                if let working = GlobalOmnibarHotkey.appliedBinding, working != "off" {
                    Text("\(GlobalHotkeyStatus.title(working)) remains registered.")
                }
                HStack {
                    Button("Retry \(GlobalHotkeyStatus.title(chord))") { GlobalOmnibarHotkey.retry() }
                    let alternate = chord == "optSpace" ? "ctrlOptSpace" : "optSpace"
                    Button("Use \(GlobalHotkeyStatus.title(alternate))") { _ = GlobalOmnibarHotkey.select(alternate) }
                }
            }
            Text("Other apps' global shortcuts aren't fully checked.").foregroundStyle(.secondary)
            if status.undo != nil {
                Button("Undo global shortcut change") {
                    message = GlobalOmnibarHotkey.undoChange() ? "Previous shortcut restored." : "The previous shortcut couldn't be restored. Review its current availability."
                }
            }
            if let message { Text(message) }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
    }
}
#endif
