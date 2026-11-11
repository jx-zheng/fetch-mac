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
        private var dragStartScreen: NSPoint?

        override var mouseDownCanMoveWindow: Bool { false }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount >= 2 {
                dragOrigin = nil
                dragStartScreen = nil
                TitlebarActions.doubleClick(window)
                return
            }
            guard let window else { return }
            dragOrigin = window.frame.origin
            dragStartScreen = window.convertPoint(toScreen: event.locationInWindow)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window, let dragOrigin, let dragStartScreen else { return }
            let current = window.convertPoint(toScreen: event.locationInWindow)
            window.setFrameOrigin(NSPoint(
                x: dragOrigin.x + (current.x - dragStartScreen.x),
                y: dragOrigin.y + (current.y - dragStartScreen.y)
            ))
        }

        override func mouseUp(with event: NSEvent) {
            dragOrigin = nil
            dragStartScreen = nil
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
    enum Action: String {
        case none, minimize, zoom
    }

    /// Set by the double-click handler so the title-bar check can see that it ran.
    static var performed: Action?

    /// Uses System Settings → Desktop & Dock → “Double-click a window’s title bar to”.
    static func doubleClick(_ window: NSWindow?) {
        guard let window else { return }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize" {
        case "None":
            performed = .none
        case "Minimize":
            performed = .minimize
            window.miniaturize(nil)
        default:
            performed = .zoom
            window.zoom(nil)
        }
    }
}

/// A non-interactive view whose frame the title-bar and hit-target checks measure.
struct LayoutMarker: NSViewRepresentable {
    var name: String

    func makeNSView(context: Context) -> LayoutMarkerView {
        let view = LayoutMarkerView()
        view.markerName = name
        return view
    }

    func updateNSView(_ view: LayoutMarkerView, context: Context) {
        view.markerName = name
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LayoutMarkerView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }
}

private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class LayoutMarkerView: NSView {
    var markerName: String = "" {
        didSet { identifier = NSUserInterfaceItemIdentifier(markerName) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func find(_ name: String, in root: NSView) -> LayoutMarkerView? {
        if let marker = root as? LayoutMarkerView, marker.markerName == name { return marker }
        for child in root.subviews {
            if let found = find(name, in: child) { return found }
        }
        return nil
    }
}

/// Reads the window's top safe area, which is the traffic-light bar.
struct TitleBarInsetReader: NSViewRepresentable {
    var onInset: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        PassthroughView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        let report = onInset
        DispatchQueue.main.async {
            let inset = view.window?.contentView?.safeAreaInsets.top ?? 0
            guard inset > 12 else { return }
            report(inset)
        }
    }
}

enum TitlebarCheck {
    private static var chromeGap: CGFloat = 0

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
            assertChrome(window, content: content, screenshot: screenshot)

            let before = window.frame.origin
            let anchor = drag.convert(NSPoint(x: drag.bounds.midX, y: drag.bounds.midY), to: nil)
            window.sendEvent(mouseEvent(.leftMouseDown, anchor, window: window, clicks: 1))
            let steps: [(CGFloat, CGFloat)] = [(10, 6), (10, 5), (10, 5), (10, 5), (8, 5)]
            var screen = window.convertToScreen(NSRect(origin: anchor, size: .zero)).origin
            for (stepX, stepY) in steps {
                screen.x += stepX
                screen.y += stepY
                let local = window.convertFromScreen(NSRect(origin: screen, size: .zero)).origin
                window.sendEvent(mouseEvent(.leftMouseDragged, local, window: window, clicks: 1))
            }
            let end = window.convertFromScreen(NSRect(origin: screen, size: .zero)).origin
            window.sendEvent(mouseEvent(.leftMouseUp, end, window: window, clicks: 1))
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
            TitlebarActions.performed = nil
            window.sendEvent(mouseEvent(.leftMouseDown, anchor, window: window, clicks: 2))
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            let performed = TitlebarActions.performed
            var zoomNote = setting
            switch setting {
            case "None":
                guard performed == .none else {
                    fail("double-click did not take the None action (performed \(performed?.rawValue ?? "nothing"))", screenshot)
                }
                guard window.frame == zoomBefore, window.isMiniaturized == miniBefore else {
                    fail("double-click ignored the None setting", screenshot)
                }
                zoomNote = "None"
            case "Minimize":
                guard performed == .minimize else {
                    fail("double-click did not take the Minimize action (performed \(performed?.rawValue ?? "nothing"))", screenshot)
                }
                guard window.isMiniaturized else { fail("double-click did not minimize", screenshot) }
                window.deminiaturize(nil)
                zoomNote = "Minimize"
            default:
                guard performed == .zoom else {
                    fail("double-click did not request zoom (performed \(performed?.rawValue ?? "nothing"))", screenshot)
                }
                if window.styleMask.contains(.resizable) {
                    guard window.isZoomed || window.frame != zoomBefore else {
                        fail("double-click did not zoom a resizable window", screenshot)
                    }
                    if window.isZoomed { window.zoom(nil) }
                    window.setFrame(zoomBefore, display: true)
                    zoomNote = "Maximize"
                } else {
                    guard !window.isMiniaturized else { fail("double-click minimized a fixed-size window", screenshot) }
                    guard window.frame == zoomBefore else {
                        fail("zoom changed a fixed-size window", screenshot)
                    }
                    zoomNote = "fixed_size_no_zoom"
                }
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
                let rep = NSBitmapImageRep(cgImage: image)
                if let png = rep.representation(using: .png, properties: [:]) {
                    let url = screenshot.deletingLastPathComponent().appendingPathComponent("titlebar-\(name).png")
                    try? png.write(to: url)
                    if name == "light" { try? png.write(to: screenshot) }
                }
            }
            let light = alphas["light"] ?? 0
            let dark = alphas["dark"] ?? 0
            print(String(format: "TITLEBAR_OK light_alpha=%.2f dark_alpha=%.2f drag_dx=%.0f drag_dy=%.0f double_click=%@ chrome_gap=%.1f", light, dark, dx, dy, zoomNote, chromeGap))
            NSApp.terminate(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: finish)
    }

    private static func assertChrome(_ window: NSWindow, content: NSView, screenshot: URL) {
        let lights = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
        guard lights.count == 3 else { fail("traffic lights are missing", screenshot) }
        guard let bar = LayoutMarkerView.find("titleBarChrome", in: content) else { fail("title bar marker missing", screenshot) }
        guard let title = LayoutMarkerView.find("windowTitle", in: content) else { fail("window title missing from the title bar", screenshot) }
        guard let gear = LayoutMarkerView.find("settingsGear", in: content) else { fail("settings gear missing from the title bar", screenshot) }
        guard let link = LayoutMarkerView.find("linkFieldChrome", in: content) else { fail("link field missing", screenshot) }
        let barRect = bar.convert(bar.bounds, to: nil)
        let titleRect = title.convert(title.bounds, to: nil)
        let gearRect = gear.convert(gear.bounds, to: nil)
        let linkRect = link.convert(link.bounds, to: nil)
        guard titleRect.width > 8, gearRect.width > 8, barRect.height > 8 else {
            fail("title bar frames are empty", screenshot)
        }
        for light in lights {
            let rect = light.convert(light.bounds, to: nil)
            guard verticalOverlap(titleRect, rect) else {
                fail("title does not share a row with the traffic lights \(rect) vs \(titleRect)", screenshot)
            }
            guard verticalOverlap(gearRect, rect) else {
                fail("gear does not share a row with the traffic lights \(rect) vs \(gearRect)", screenshot)
            }
        }
        let gap = barRect.minY - linkRect.maxY
        guard gap <= 12, gap >= -1 else {
            fail(String(format: "paste field is %.1f pt from the title bar", gap), screenshot)
        }
        chromeGap = gap
        let origin = window.frame.origin
        let gearPoint = gear.convert(NSPoint(x: gear.bounds.midX, y: gear.bounds.midY), to: nil)
        window.sendEvent(mouseEvent(.leftMouseDown, gearPoint, window: window, clicks: 1))
        let dragged = NSPoint(x: gearPoint.x + 30, y: gearPoint.y + 16)
        window.sendEvent(mouseEvent(.leftMouseDragged, dragged, window: window, clicks: 1))
        window.sendEvent(mouseEvent(.leftMouseUp, dragged, window: window, clicks: 1))
        let moved = hypot(window.frame.origin.x - origin.x, window.frame.origin.y - origin.y)
        if moved > 1.5 {
            window.setFrameOrigin(origin)
            fail(String(format: "settings gear started a drag (%.1f pt)", moved), screenshot)
        }
    }

    private static func verticalOverlap(_ a: NSRect, _ b: NSRect) -> Bool {
        min(a.maxY, b.maxY) - max(a.minY, b.minY) > 1
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
        return [4, 12, 20].flatMap { fromTop in
            xs.map { x in
                CGFloat(pixels[(fromTop * width + x) * 4 + 3]) / 255
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
