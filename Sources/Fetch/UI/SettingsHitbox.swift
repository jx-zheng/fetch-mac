import AppKit
import SwiftUI

/// Clicks the padding of each Settings tab, not its icon or title, and checks the tab changes.
enum SettingsHitboxCheck {
    @MainActor
    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let model = AppModel.shared
        let host = NSHostingView(rootView: SettingsView(model: model).frame(width: 500))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 640)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = host
        window.setContentSize(NSSize(width: 500, height: max(420, host.fittingSize.height + 40)))
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        for _ in 0..<10 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        guard LayoutMarkerView.find("settings-pane-general", in: host) != nil else {
            fail("General pane was not the initial tab")
        }
        clickPadding(of: "downloads", in: host, window: window)
        guard LayoutMarkerView.find("settings-pane-downloads", in: host) != nil else {
            fail("padding click did not select Downloads")
        }
        guard LayoutMarkerView.find("settings-pane-general", in: host) == nil else {
            fail("General stayed selected after a Downloads padding click")
        }
        clickPadding(of: "engine", in: host, window: window)
        guard LayoutMarkerView.find("settings-pane-engine", in: host) != nil else {
            fail("padding click did not select Engine")
        }
        clickPadding(of: "general", in: host, window: window)
        guard LayoutMarkerView.find("settings-pane-general", in: host) != nil else {
            fail("padding click did not select General")
        }
        print("HITBOX_OK")
        exit(0)
    }

    @MainActor
    private static func clickPadding(of tab: String, in host: NSView, window: NSWindow) {
        guard let tile = LayoutMarkerView.find("settings-tab-\(tab)", in: host) else {
            fail("\(tab) tile is missing")
        }
        guard let label = LayoutMarkerView.find("settings-tab-\(tab)-label", in: host),
              let icon = LayoutMarkerView.find("settings-tab-\(tab)-icon", in: host) else {
            fail("\(tab) label is missing")
        }
        let tileRect = tile.convert(tile.bounds, to: nil)
        let labelRect = label.convert(label.bounds, to: nil)
        let iconRect = icon.convert(icon.bounds, to: nil)
        guard tileRect.width > labelRect.width + 8, tileRect.height > iconRect.height + labelRect.height else {
            fail("\(tab) tile has no padding around its contents \(tileRect)")
        }
        let local = NSPoint(x: 3, y: tile.isFlipped ? 3 : tile.bounds.height - 3)
        let point = tile.convert(local, to: nil)
        guard tileRect.insetBy(dx: 1, dy: 1).contains(point) else {
            fail("\(tab) padding corner is outside the tile")
        }
        guard !labelRect.contains(point), !iconRect.contains(point) else {
            fail("\(tab) padding corner landed on the icon or the title")
        }
        let down = mouseEvent(.leftMouseDown, point, window: window)
        let up = mouseEvent(.leftMouseUp, point, window: window)
        window.sendEvent(down)
        window.sendEvent(up)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        if LayoutMarkerView.find("settings-pane-\(tab)", in: host) == nil, let hit = window.contentView?.hitTest(point) {
            let message = "HITBOX_FALLBACK \(tab) direct mouseDown on \(type(of: hit))\n"
            FileHandle.standardOutput.write(Data(message.utf8))
            FileHandle.standardError.write(Data(message.utf8))
            hit.mouseDown(with: down)
            hit.mouseUp(with: up)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    private static func mouseEvent(_ type: NSEvent.EventType, _ location: NSPoint, window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )!
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("HITBOX_FAIL \(message)\n".utf8))
        exit(1)
    }
}
