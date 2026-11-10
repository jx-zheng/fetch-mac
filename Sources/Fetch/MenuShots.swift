import AppKit
import FetchCore
import SwiftUI

/// Opens the real Quality menu after resolving a real link, in light and dark.
enum MenuShots {
    @MainActor
    static func run(directory: URL, media: String) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = AppModel.shared
        model.urlText = media
        model.container = .mp4H264
        let generation = await model.resolveForMenuShots()
        guard generation, case .preview = model.phase else {
            fail("resolve did not reach a preview for \(media)")
        }
        let root = MenuShotRoot(model: model)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 540, height: 640)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Fetch"
        window.contentView = hosting
        window.setContentSize(NSSize(width: 540, height: max(460, hosting.fittingSize.height)))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        for _ in 0..<6 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        let shots: [(String, NSAppearance.Name, ContainerFormat)] = [
            ("quality-video-light", .aqua, .mp4H264),
            ("quality-video-dark", .darkAqua, .mp4H264),
            ("quality-audio-light", .aqua, .mp3),
            ("quality-audio-dark", .darkAqua, .mp3),
        ]
        for (name, appearance, container) in shots {
            let look = NSAppearance(named: appearance)
            NSApp.appearance = look
            window.appearance = look
            model.container = container
            window.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            guard let popup = findQualityPopup(in: hosting) else {
                fail("quality popup not found for \(name)")
            }
            captureOpenMenu(popup, window: window, to: directory.appendingPathComponent("\(name).png"))
        }
        print("MENU_SHOTS_OK \(directory.path)")
        NSApp.terminate(nil)
    }

    private static func findQualityPopup(in view: NSView) -> NSPopUpButton? {
        let popups = collectPopups(in: view)
        if let marked = popups.first(where: { $0.accessibilityIdentifier() == "qualityPicker" }) {
            return marked
        }
        return popups.first { popup in
            guard let menu = popup.menu else { return false }
            let titles = menu.items.map(\.title)
            return titles.contains("Best") && (titles.contains { $0.contains("kbps") || $0.hasSuffix("p") })
        }
    }

    private static func collectPopups(in view: NSView) -> [NSPopUpButton] {
        var found: [NSPopUpButton] = []
        if let popup = view as? NSPopUpButton { found.append(popup) }
        for subview in view.subviews {
            found.append(contentsOf: collectPopups(in: subview))
        }
        return found
    }

    private static func captureOpenMenu(_ popup: NSPopUpButton, window: NSWindow, to url: URL) {
        let timer = Timer(timeInterval: 0.45, repeats: false) { _ in
            saveCapture(around: window, to: url)
            popup.menu?.cancelTracking()
        }
        RunLoop.current.add(timer, forMode: .common)
        popup.performClick(nil)
    }

    private static func saveCapture(around window: NSWindow, to url: URL) {
        let screen = window.screen ?? NSScreen.main
        let screenHeight = screen?.frame.height ?? 0
        var rect = window.frame.insetBy(dx: -30, dy: -220)
        if let screen {
            rect = rect.intersection(screen.frame.insetBy(dx: -20, dy: -20))
        }
        let cgRect = CGRect(x: rect.minX, y: screenHeight - rect.maxY, width: rect.width, height: rect.height)
        guard let image = CGWindowListCreateImage(cgRect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution, .boundsIgnoreFraming]) else {
            fail("couldn't capture \(url.lastPathComponent)")
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            fail("couldn't capture \(url.lastPathComponent)")
        }
        do {
            try png.write(to: url)
        } catch {
            fail("couldn't write \(url.path): \(error)")
        }
        FileHandle.standardError.write(Data("wrote \(url.path)\n".utf8))
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("MENU_SHOTS_FAIL \(message)\n".utf8))
        exit(1)
    }
}

private struct MenuShotRoot: View {
    @ObservedObject var model: AppModel

    var body: some View {
        MainView(
            urlText: $model.urlText,
            container: $model.container,
            quality: $model.quality,
            maxSizeEnabled: $model.maxSizeEnabled,
            maxSizeText: $model.maxSizeText,
            phase: model.phase,
            clipboardOffer: model.clipboardOffer,
            sourceHeights: model.sourceHeights,
            saveName: model.saveName,
            dropActive: false,
            actions: MainActions()
        )
    }
}
