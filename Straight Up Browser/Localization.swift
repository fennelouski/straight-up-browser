//
//  Localization.swift
//  Straight Up Browser
//

import Foundation

extension String {
    /// Localizes a string whose key is only known at runtime — enum labels and static
    /// data tables that get rendered through `Text(variable)`. Literal `Text("…")` and
    /// `String(localized:)` sites localize on their own; this is only for the runtime-key
    /// cases, and every such key must exist in `Localizable.xcstrings`.
    var localized: String { NSLocalizedString(self, comment: "") }
}
