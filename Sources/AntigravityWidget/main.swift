import AppKit

// Menu-bar accessory app: no Dock icon, no main menu; just the floating panel
// and a status item.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
