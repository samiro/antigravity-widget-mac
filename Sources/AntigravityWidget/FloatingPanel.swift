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
        isMovable = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow

        let hosting = NSHostingView(rootView: content())
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = hosting

        restorePosition()
        let initialSize = hosting.fittingSize
        if initialSize.width > 10, initialSize.height > 10 {
            fit(to: initialSize)
        }
        invalidateShadow()

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

    private var dragStartMouseLocation: NSPoint?
    private var dragStartWindowOrigin: NSPoint?
    private var isDraggingWindow = false

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            dragStartMouseLocation = NSEvent.mouseLocation
            dragStartWindowOrigin = frame.origin
            isDraggingWindow = false
            super.sendEvent(event)

        case .leftMouseDragged:
            if let startMouse = dragStartMouseLocation, let startOrigin = dragStartWindowOrigin {
                let currentMouse = NSEvent.mouseLocation
                let deltaX = currentMouse.x - startMouse.x
                let deltaY = currentMouse.y - startMouse.y

                if !isDraggingWindow && (abs(deltaX) >= 3 || abs(deltaY) >= 3) {
                    isDraggingWindow = true
                }

                if isDraggingWindow {
                    var newOrigin = NSPoint(x: startOrigin.x + deltaX, y: startOrigin.y + deltaY)
                    let targetScreen = NSScreen.screens.first { NSMouseInRect(currentMouse, $0.frame, false) }
                        ?? screen
                        ?? NSScreen.main
                    if let visible = targetScreen?.visibleFrame {
                        newOrigin.x = min(max(newOrigin.x, visible.minX), visible.maxX - frame.width)
                        newOrigin.y = min(max(newOrigin.y, visible.minY), visible.maxY - frame.height)
                    }
                    setFrameOrigin(newOrigin)
                    return
                }
            }
            super.sendEvent(event)

        case .leftMouseUp:
            let wasDragging = isDraggingWindow
            dragStartMouseLocation = nil
            dragStartWindowOrigin = nil
            isDraggingWindow = false

            if wasDragging {
                savePosition()
                // Cancel any pending control highlights by sending mouse-up far outside the window bounds.
                if let cancelEvent = NSEvent.mouseEvent(
                    with: .leftMouseUp,
                    location: NSPoint(x: -10000, y: -10000),
                    modifierFlags: event.modifierFlags,
                    timestamp: event.timestamp,
                    windowNumber: windowNumber,
                    context: nil,
                    eventNumber: event.eventNumber,
                    clickCount: 0,
                    pressure: 0.0
                ) {
                    super.sendEvent(cancelEvent)
                }
                return
            }
            super.sendEvent(event)

        default:
            super.sendEvent(event)
        }
    }

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
            invalidateShadow()
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
