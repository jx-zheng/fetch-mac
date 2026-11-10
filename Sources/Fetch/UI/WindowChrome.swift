import AppKit
import SwiftUI

/// Fills the title strip and drags the window from anywhere that isn't a control.
struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }

    func updateNSView(_ view: DragView, context: Context) {
        view.configureWindow()
    }

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            guard let window else { return }
            window.isMovable = true
            window.isMovableByWindowBackground = true
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

enum TitlebarCheck {
    static func run(saving screenshot: URL) {
        func finish() {
            guard let window = NSApp.windows.first(where: { $0.isVisible && ($0.title == "Fetch" || $0.identifier?.rawValue == "main") }) else {
                fail("no Fetch window", screenshot)
            }
            guard window.isMovable else { fail("window is not movable", screenshot) }
            guard window.isMovableByWindowBackground else { fail("window is not movable by its background", screenshot) }
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
            guard buttons.count == 3, buttons.allSatisfy({ !$0.isHidden }) else {
                fail("traffic lights are missing", screenshot)
            }
            guard let content = window.contentView else { fail("no content view", screenshot) }
            var canDrag = false
            for dy in [8, 18, 28, 40] {
                let y = content.isFlipped ? CGFloat(dy) : content.bounds.maxY - CGFloat(dy)
                let point = NSPoint(x: content.bounds.midX, y: y)
                var view = content.hitTest(content.convert(point, to: nil))
                while let current = view {
                    if current.mouseDownCanMoveWindow { canDrag = true; break }
                    view = current.superview
                }
                if canDrag { break }
            }
            guard canDrag else { fail("title drag region was not hit", screenshot) }

            window.hasShadow = false
            window.displayIfNeeded()
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else {
                fail("couldn't capture the window", screenshot)
            }
            let rep = NSBitmapImageRep(cgImage: image)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: screenshot)
            }
            let samples = sampleTitleStrip(rep)
            guard let minAlpha = samples.min(), minAlpha > 0.9 else {
                fail("title bar is transparent (alphas \(samples))", screenshot)
            }
            print(String(format: "TITLEBAR_OK alpha=%.2f drag=true movable=true buttons=3", minAlpha))
            NSApp.terminate(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: finish)
    }

    private static func sampleTitleStrip(_ rep: NSBitmapImageRep) -> [CGFloat] {
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        guard width > 10, height > 20 else { return [0] }
        let top = height - 1
        let xs = [width / 2, min(width - 8, 90), max(8, width - 40)]
        let ys = [top - 4, top - 12, top - 20]
        return ys.flatMap { y in xs.map { x in rep.colorAt(x: x, y: y)?.alphaComponent ?? 0 } }
    }

    private static func fail(_ message: String, _ screenshot: URL) -> Never {
        FileHandle.standardError.write(Data(("TITLEBAR_FAIL \(message)\n").utf8))
        _ = screenshot
        exit(1)
    }
}
