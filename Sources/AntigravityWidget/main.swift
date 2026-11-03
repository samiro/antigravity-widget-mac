import AppKit

// Menu-bar accessory app: no Dock icon, no main menu; just the floating panel
// and a status item.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    if let idx = CommandLine.arguments.firstIndex(of: "--render-screenshots"),
       CommandLine.arguments.count > idx + 1 {
        let dir = URL(fileURLWithPath: CommandLine.arguments[idx + 1])
        ScreenshotGenerator.generate(to: dir)
        exit(0)
    }

    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) {
        app.run()
    }
}
