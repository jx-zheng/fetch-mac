import AppKit
import SwiftUI

/// Fills the title strip and drags the window from anywhere that isn't a control.
struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }

    func updateNSView(_ view: DragView, context: Context) {
        view.configureWindow()
    }

    final class DragView: NSView {
        private var dragOrigin: NSPoint?
        private var dragStart: NSPoint?

        override var mouseDownCanMoveWindow: Bool { false }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount >= 2 {
                dragOrigin = nil
                TitlebarActions.doubleClick(window)
                return
            }
            dragOrigin = window?.frame.origin
            dragStart = event.locationInWindow
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window, let dragOrigin, let dragStart else { return }
            let dx = event.locationInWindow.x - dragStart.x
            let dy = event.locationInWindow.y - dragStart.y
            window.setFrameOrigin(NSPoint(x: dragOrigin.x + dx, y: dragOrigin.y + dy))
        }

        override func mouseUp(with event: NSEvent) {
            dragOrigin = nil
            dragStart = nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            guard let window else { return }
            window.isMovable = true
            window.isMovableByWindowBackground = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.styleMask.insert(.fullSizeContentView)
            window.styleMask.insert(.titled)
            window.styleMask.insert(.closable)
            window.styleMask.insert(.miniaturizable)
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(kind)?.isHidden = false
            }
        }
    }
}

enum TitlebarActions {
    /// Uses System Settings → Desktop & Dock → “Double-click a window’s title bar to”.
    static func doubleClick(_ window: NSWindow?) {
        guard let window else { return }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize" {
        case "None":
            break
        case "Minimize":
            window.miniaturize(nil)
        default:
            window.zoom(nil)
        }
    }
}

enum TitlebarCheck {
    static func run(saving screenshot: URL) {
        func finish() {
            guard let window = NSApp.windows.first(where: { $0.isVisible && ($0.title == "Fetch" || $0.identifier?.rawValue == "main") }) else {
                fail("no Fetch window", screenshot)
            }
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
            guard buttons.count == 3, buttons.allSatisfy({ !$0.isHidden }) else {
                fail("traffic lights are missing", screenshot)
            }
            guard let content = window.contentView else { fail("no content view", screenshot) }
            guard let drag = titleDragView(in: content) else { fail("title drag region was not hit", screenshot) }
            guard !bodyContainsDragView(content) else { fail("empty window body is draggable", screenshot) }

            let before = window.frame.origin
            let start = NSPoint(x: 80, y: 40)
            drag.mouseDown(with: mouseEvent(.leftMouseDown, start, window: window, clicks: 1))
            drag.mouseDragged(with: mouseEvent(.leftMouseDragged, NSPoint(x: start.x + 48, y: start.y + 26), window: window, clicks: 1))
            drag.mouseUp(with: mouseEvent(.leftMouseUp, NSPoint(x: start.x + 48, y: start.y + 26), window: window, clicks: 1))
            let moved = window.frame.origin
            let dx = moved.x - before.x
            let dy = moved.y - before.y
            guard abs(dx - 48) < 0.5, abs(dy - 26) < 0.5 else {
                fail("synthetic drag did not move the window (\(dx), \(dy))", screenshot)
            }
            window.setFrameOrigin(before)

            let setting = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            let zoomBefore = window.frame
            let miniBefore = window.isMiniaturized
            let wasResizable = window.styleMask.contains(.resizable)
            if setting != "None" && setting != "Minimize" {
                window.styleMask.insert(.resizable)
            }
            drag.mouseDown(with: mouseEvent(.leftMouseDown, start, window: window, clicks: 2))
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            switch setting {
            case "None":
                guard window.frame == zoomBefore, window.isMiniaturized == miniBefore else {
                    fail("double-click ignored the None setting", screenshot)
                }
            case "Minimize":
                guard window.isMiniaturized else { fail("double-click did not minimize", screenshot) }
                window.deminiaturize(nil)
            default:
                guard window.isZoomed || window.frame != zoomBefore else {
                    fail("double-click did not zoom", screenshot)
                }
                if window.isZoomed { window.zoom(nil) }
                window.setFrame(zoomBefore, display: true)
                if !wasResizable { window.styleMask.remove(.resizable) }
            }

            window.hasShadow = false
            var alphas: [String: CGFloat] = [:]
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                let look = NSAppearance(named: appearance)
                NSApp.appearance = look
                window.appearance = look
                window.displayIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else {
                    fail("couldn't capture the \(name) window", screenshot)
                }
                let samples = topRowAlphas(image)
                guard let minAlpha = samples.min(), minAlpha > 0.9 else {
                    fail("\(name) title bar is transparent (alphas \(samples))", screenshot)
                }
                alphas[name] = minAlpha
                if let rep = NSBitmapImageRep(cgImage: image), let png = rep.representation(using: .png, properties: [:]) {
                    let url = screenshot.deletingLastPathComponent().appendingPathComponent("titlebar-\(name).png")
                    try? png.write(to: url)
                    if name == "light" { try? png.write(to: screenshot) }
                }
            }
            let light = alphas["light"] ?? 0
            let dark = alphas["dark"] ?? 0
            print(String(format: "TITLEBAR_OK light_alpha=%.2f dark_alpha=%.2f drag_dx=%.0f drag_dy=%.0f double_click=%@", light, dark, dx, dy, setting))
            NSApp.terminate(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: finish)
    }

    /// CGImage row 0 is the top of the window. Sample those rows, not the bottom.
    private static func topRowAlphas(_ image: CGImage) -> [CGFloat] {
        let width = image.width
        let height = image.height
        guard width > 10, height > 24 else { return [0] }
        let rowBytes = width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: rowBytes,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [0] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let xs = [width / 2, min(width - 8, 90), max(8, width - 40)]
        // Context origin is the bottom, so the top rows are the last ones in the buffer.
        return [4, 12, 20].flatMap { fromTop in
            let y = height - 1 - fromTop
            return xs.map { x in
                CGFloat(pixels[(y * width + x) * 4 + 3]) / 255
            }
        }
    }

    private static func titleDragView(in content: NSView) -> WindowDragRegion.DragView? {
        for dy in [8, 18, 28, 40] {
            let y = content.isFlipped ? CGFloat(dy) : content.bounds.maxY - CGFloat(dy)
            let point = NSPoint(x: content.bounds.midX, y: y)
            var view = content.hitTest(content.convert(point, to: nil))
            while let current = view {
                if let drag = current as? WindowDragRegion.DragView { return drag }
                view = current.superview
            }
        }
        return nil
    }

    private static func bodyContainsDragView(_ content: NSView) -> Bool {
        let point = NSPoint(x: content.bounds.midX, y: content.bounds.midY)
        var view = content.hitTest(content.convert(point, to: nil))
        while let current = view {
            if current is WindowDragRegion.DragView { return true }
            view = current.superview
        }
        return false
    }

    private static func mouseEvent(_ type: NSEvent.EventType, _ location: NSPoint, window: NSWindow, clicks: Int) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: clicks,
            pressure: 1
        )!
    }

    private static func fail(_ message: String, _ screenshot: URL) -> Never {
        FileHandle.standardError.write(Data(("TITLEBAR_FAIL \(message)\n").utf8))
        _ = screenshot
        exit(1)
    }
}
