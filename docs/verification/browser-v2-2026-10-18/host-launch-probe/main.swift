import AppKit

// Background-only diagnostic host. No windows, network, preferences or data.
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.run()
