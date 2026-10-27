import AppKit
import SwiftUI

/// A borderless, translucent, always-on-top panel that floats over every Space
/// (including full-screen apps) without stealing focus from the active app.
final class FloatingPanel: NSPanel {
    private static let originKey = "widget.topLeft"

    init<Content: View>(@ViewBuilder content: () -> Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow

        let hosting = NSHostingView(rootView: content())
        hosting.sizingOptions = [] // we size the window from SwiftUI's reported size
        contentView = hosting

        restorePosition()

        // Persist the position whenever the user drags the widget.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: self, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.savePosition() }
        }
    }

    // Borderless panels can't become key by default; allow it so buttons/menus work.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Resizes the panel keeping its top-left corner fixed, clamped to the screen.
    func fit(to size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let topLeft = NSPoint(x: frame.minX, y: frame.maxY)
        var newFrame = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        if let visible = (screen ?? NSScreen.main)?.visibleFrame {
            newFrame.origin.x = min(max(newFrame.minX, visible.minX), visible.maxX - newFrame.width)
            newFrame.origin.y = min(max(newFrame.minY, visible.minY), visible.maxY - newFrame.height)
        }
        if newFrame != frame {
            setFrame(newFrame, display: true, animate: false)
        }
    }

    func savePosition() {
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: frame.minX, y: frame.maxY)), forKey: Self.originKey)
    }

    private func restorePosition() {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var topLeft = NSPoint(x: visible.maxX - 320, y: visible.maxY - 20)
        if let saved = UserDefaults.standard.string(forKey: Self.originKey) {
            let p = NSPointFromString(saved)
            // Only reuse if it's still on some connected screen.
            if NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -4, dy: -4).contains(p) }) {
                topLeft = p
            }
        }
        setFrameTopLeftPoint(topLeft)
    }

    /// Moves the widget back to the top-right corner of the main screen.
    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: Self.originKey)
        restorePosition()
        savePosition()
    }
}
