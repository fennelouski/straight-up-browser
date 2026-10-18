import SwiftUI

/// One observable authority invalidates every window when theme changes. This
/// wrapper never imports a raw UserDefaults change after the one-time migration.
@MainActor @propertyWrapper struct BrowserThemeStorage: DynamicProperty {
    @State private var owner: BrowserThemeStore
    init() { _owner = State(initialValue: BrowserThemeStore.shared) }
    init(owner: BrowserThemeStore) { _owner = State(initialValue: owner) }
    var wrappedValue: String {
        get { owner.value }
        nonmutating set { owner.setManually(newValue) }
    }
    var projectedValue: Binding<String> {
        Binding(get: { owner.value }, set: { owner.setManually($0) })
    }
}
