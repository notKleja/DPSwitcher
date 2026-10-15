import AppKit
import CoreGraphics

/// MonitorControl-compatible software brightness shade. The shielding window
/// level keeps the layer out of normal window capture while still covering the
/// physical display.
final class PersistentBlackShade {
    private var shades: [CGDirectDisplayID: NSWindow] = [:]
    private(set) var isActive = false

    func show() {
        isActive = true
        refresh()
    }

    func hide() {
        isActive = false
        for shade in shades.values {
            shade.close()
        }
        shades.removeAll()
    }

    func refresh() {
        guard isActive else { return }
        let externalScreens = NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, NSScreen)? in
            guard
                let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            let displayID = CGDirectDisplayID(number.uint32Value)
            guard CGDisplayIsBuiltin(displayID) == 0 else { return nil }
            return (displayID, screen)
        }

        let activeIDs = Set(externalScreens.map(\.0))
        for (displayID, shade) in shades where !activeIDs.contains(displayID) {
            shade.close()
            shades.removeValue(forKey: displayID)
        }

        for (displayID, screen) in externalScreens {
            let shade = shades[displayID] ?? createShade(displayID: displayID)
            shades[displayID] = shade
            shade.setFrame(screen.frame, display: true)
            shade.contentView?.alphaValue = 1.0
            shade.orderFrontRegardless()
        }
    }

    private func createShade(displayID: CGDirectDisplayID) -> NSWindow {
        // This intentionally mirrors MonitorControl's DisplayManager shade.
        let shade = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 10, height: 1)),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        shade.title = "Monitor Control Window Shade for Display \(displayID)"
        shade.isMovableByWindowBackground = false
        shade.backgroundColor = .clear
        shade.ignoresMouseEvents = true
        shade.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        shade.collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle]
        shade.contentView?.wantsLayer = true
        shade.contentView?.alphaValue = 1.0
        shade.contentView?.layer?.backgroundColor = NSColor.black.cgColor
        shade.orderFrontRegardless()
        return shade
    }
}
