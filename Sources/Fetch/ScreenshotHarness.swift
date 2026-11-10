import AppKit
import FetchCore
import SwiftUI

enum ScreenshotHarness {
    @MainActor
    static func run(directory: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = AppModel.shared
        model.container = .mp4H264
        model.watchClipboard = false
        model.showMenuBar = true
        model.ytDlpVersion = "2026.10.26"
        model.denoVersion = "2.9.8"
        model.ffmpegVersion = "9.0"
        model.engineStatus = "Up to date · checked today"

        let shots: [(String, ColorScheme, AnyView)] = [
            ("empty", .light, AnyView(main(.empty, url: "", max: "", enabled: false))),
            ("empty", .dark, AnyView(main(.empty, url: "", max: "", enabled: false))),
            ("preview", .light, AnyView(main(.preview(tiktok), url: tiktokURL, max: "25", enabled: true))),
            ("preview", .dark, AnyView(main(.preview(tiktok), url: tiktokURL, max: "25", enabled: true))),
            ("progress", .light, AnyView(main(.downloading(youtube, progress), url: youtubeURL, max: "50", enabled: true))),
            ("progress", .dark, AnyView(main(.downloading(youtube, progress), url: youtubeURL, max: "50", enabled: true))),
            ("completed", .light, AnyView(main(.completed(completed), url: "", max: "50", enabled: true))),
            ("completed", .dark, AnyView(main(.completed(completed), url: "", max: "50", enabled: true))),
            ("error", .light, AnyView(main(.failed(instagram), url: instagramURL, max: "", enabled: false))),
            ("error", .dark, AnyView(main(.failed(instagram), url: instagramURL, max: "", enabled: false))),
            ("clipboard", .light, AnyView(main(.empty, url: "", max: "", enabled: false, offer: "https://www.youtube.com/watch?v=BaW_jenozKc"))),
            ("clipboard", .dark, AnyView(main(.empty, url: "", max: "", enabled: false, offer: "https://www.youtube.com/watch?v=BaW_jenozKc"))),
            ("fulldisk", .light, AnyView(main(.failed(fullDisk), url: instagramURL, max: "", enabled: false))),
            ("fulldisk", .dark, AnyView(main(.failed(fullDisk), url: instagramURL, max: "", enabled: false))),
            ("ready", .light, AnyView(main(.preview(youtubeReady), url: youtubeURL, max: "50", enabled: true, container: .mp4H264, quality: .p1080, heights: [1080, 720, 480]))),
            ("ready", .dark, AnyView(main(.preview(youtubeReady), url: youtubeURL, max: "50", enabled: true, container: .mp4H264, quality: .p1080, heights: [1080, 720, 480]))),
            ("quality-video", .light, AnyView(main(.preview(youtubeReady), url: youtubeURL, max: "50", enabled: true, container: .mp4H264, quality: .p1080, heights: [1080, 720, 480], menu: true))),
            ("quality-video", .dark, AnyView(main(.preview(youtubeReady), url: youtubeURL, max: "50", enabled: true, container: .mp4H264, quality: .p1080, heights: [1080, 720, 480], menu: true))),
            ("quality-audio", .light, AnyView(main(.preview(audioReady), url: youtubeURL, max: "", enabled: false, container: .mp3, quality: .best, heights: [1080, 720], menu: true))),
            ("quality-audio", .dark, AnyView(main(.preview(audioReady), url: youtubeURL, max: "", enabled: false, container: .mp3, quality: .best, heights: [1080, 720], menu: true))),
            ("settings", .light, AnyView(settings)),
            ("settings", .dark, AnyView(settings)),
        ]

        var failed = false
        for (name, scheme, view) in shots {
            let suffix = scheme == .dark ? "dark" : "light"
            let url = directory.appendingPathComponent("\(name)-\(suffix).png")
            do {
                let image = try capture(view, scheme: scheme, width: name == "settings" ? 500 : 540)
                try write(image, to: url)
                if isMostlyBlank(image) || fileSize(url) < 8_000 {
                    note("blank screenshot \(url.lastPathComponent)")
                    failed = true
                } else {
                    note("wrote \(url.path)")
                }
            } catch {
                note("screenshot \(name)-\(suffix) failed: \(error)")
                failed = true
            }
        }
        exit(Int32(failed ? 1 : 0))
    }

    private static func note(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    @MainActor
    private static func capture<V: View>(_ view: V, scheme: ColorScheme, width: CGFloat) throws -> NSImage {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let root = view
            .environment(\.colorScheme, scheme)
            .frame(width: width)
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = appearance
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 720)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        for _ in 0..<8 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        hosting.layoutSubtreeIfNeeded()
        var height = hosting.fittingSize.height
        if height < 200 || height > 900 { height = 460 }
        let size = NSSize(width: width, height: height)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let image = NSImage(size: size)
            image.addRepresentation(rep)
            if !isMostlyBlank(image) {
                window.orderOut(nil)
                return image
            }
        }

        let renderer = ImageRenderer(content: root.frame(width: width, height: height))
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: width, height: height)
        if let image = renderer.nsImage {
            window.orderOut(nil)
            return image
        }
        window.orderOut(nil)
        throw CocoaError(.fileWriteUnknown)
    }

    private static func write(_ image: NSImage, to url: URL) throws {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }

    private static func isMostlyBlank(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return true }
        var colored = 0
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        guard width > 0, height > 0 else { return true }
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                if color.alphaComponent > 0.2 { colored += 1 }
            }
        }
        return colored < 30
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    private static func main(
        _ phase: ScreenPhase,
        url: String,
        max: String,
        enabled: Bool,
        offer: String? = nil,
        container: ContainerFormat = .mp4H264,
        quality: Quality = .best,
        heights: [Int] = [],
        menu: Bool = false
    ) -> some View {
        Shot(phase: phase, url: url, max: max, enabled: enabled, offer: offer, container: container, quality: quality, heights: heights, menu: menu)
    }

    private static var settings: some View {
        SettingsShot()
    }

    private static let tiktokURL = "tiktok.com/@kyotowalks/video/7431958820114"
    private static let youtubeURL = "youtube.com/watch?v=Qf3n8Lk2pVE"
    private static let instagramURL = "instagram.com/reel/C9xT2mQp4Lk"

    private static var tiktok: PreviewContent {
        PreviewContent(
            title: "Golden hour on the Philosopher's Path — the quietest 47 seconds in Kyoto",
            site: "TikTok",
            author: "@kyotowalks",
            resolution: "1080 × 1920",
            duration: "0:47",
            thumbnail: nil,
            portrait: true,
            badges: [
                PreviewBadge(id: "clean", text: "No watermark", good: true),
                PreviewBadge(id: "size", text: "≈ 18.6 MB", good: false),
                PreviewBadge(id: "codec", text: "H.264 · AAC", good: false),
            ]
        )
    }

    private static var youtube: PreviewContent {
        PreviewContent(
            title: "How a Mechanical Watch Actually Works",
            site: "YouTube",
            author: "Horology Bench",
            resolution: nil,
            duration: "12:08",
            thumbnail: nil,
            portrait: false,
            badges: []
        )
    }

    private static var progress: ProgressContent {
        ProgressContent(fraction: 0.62, headline: "Fitting to 50 MB", stage: "Encoding · pass 2 of 2 · Apple hardware encoder", trailing: "62% · 9 s left")
    }

    private static var youtubeReady: PreviewContent {
        PreviewContent(
            title: "How a Mechanical Watch Actually Works",
            site: "YouTube",
            author: "Veritasium",
            resolution: "1920×1080",
            duration: "12:08",
            thumbnail: nil,
            portrait: false,
            badges: [
                PreviewBadge(id: "size", text: "≈ 48 MB", good: false),
                PreviewBadge(id: "codec", text: "H.264 · AAC", good: false),
            ]
        )
    }

    private static var audioReady: PreviewContent {
        PreviewContent(
            title: "How a Mechanical Watch Actually Works",
            site: "YouTube",
            author: "Veritasium",
            resolution: nil,
            duration: "12:08",
            thumbnail: nil,
            portrait: false,
            badges: [
                PreviewBadge(id: "size", text: "≈ 3.3 MB", good: false),
                PreviewBadge(id: "codec", text: "MP3", good: false),
            ]
        )
    }

    private static var completed: CompletedContent {
        CompletedContent(filename: "How a Mechanical Watch Actually Works.mp4", detail: "48.7 MB · 1080p · H.264 · fits under 50 MB", fileURL: nil)
    }

    private static var fullDisk: PresentedProblem {
        PresentedProblem(
            title: "Fetch needs Full Disk Access",
            message: "Safari keeps its sign-in in a protected file. Turn on Full Disk Access for Fetch, then try this one download again. System Settings → Privacy & Security → Full Disk Access.",
            detail: "Cookies.binarycookies",
            primaryTitle: "Open Full Disk Access",
            primary: .fullDiskAccess,
            secondaryTitle: "Try again",
            secondary: .retry
        )
    }

    private static var instagram: PresentedProblem {
        PresentedProblem(
            title: "Instagram needs you signed in",
            message: "This reel isn't public to logged-out visitors. Fetch can borrow your Safari sign-in for this one download, read-only.",
            detail: "login required · instagram:reel",
            primaryTitle: "Use Safari sign-in",
            primary: .safari,
            secondaryTitle: "Try again",
            secondary: .retry
        )
    }
}

private struct Shot: View {
    @State var urlText: String
    @State var container: ContainerFormat = .mp4H264
    @State var quality: Quality = .best
    @State var maxSizeEnabled: Bool
    @State var maxSizeText: String
    var phase: ScreenPhase
    var offer: String?
    var heights: [Int]
    var menu: Bool

    init(phase: ScreenPhase, url: String, max: String, enabled: Bool, offer: String? = nil, container: ContainerFormat = .mp4H264, quality: Quality = .best, heights: [Int] = [], menu: Bool = false) {
        self.phase = phase
        self.offer = offer
        self.heights = heights
        self.menu = menu
        _urlText = State(initialValue: url)
        _container = State(initialValue: container)
        _quality = State(initialValue: quality)
        _maxSizeText = State(initialValue: max)
        _maxSizeEnabled = State(initialValue: enabled)
    }

    var body: some View {
        MainView(
            urlText: $urlText,
            container: $container,
            quality: $quality,
            maxSizeEnabled: $maxSizeEnabled,
            maxSizeText: $maxSizeText,
            phase: phase,
            clipboardOffer: offer,
            sourceHeights: heights,
            showsQualityMenu: menu,
            saveName: "Downloads",
            dropActive: false,
            actions: MainActions()
        )
    }
}

private struct SettingsShot: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        SettingsView(model: model)
            .onAppear {
                model.container = .mp4H264
                model.watchClipboard = false
                model.showMenuBar = true
                model.ytDlpVersion = "2026.10.26"
                model.denoVersion = "2.9.8"
                model.ffmpegVersion = "9.0"
                model.engineStatus = "Up to date · checked today"
            }
    }
}
