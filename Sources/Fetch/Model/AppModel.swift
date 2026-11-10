import AppKit
import FetchCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var urlText = ""
    @Published var phase: ScreenPhase = .empty
    @Published var container: ContainerFormat { didSet { persist(.container); refreshPlan() } }
    @Published var quality: Quality { didSet { persist(.quality); refreshPlan() } }
    @Published var maxSizeEnabled: Bool { didSet { persist(.maxSize); refreshPlan() } }
    @Published var maxSizeText: String { didSet { clampMaxSize() } }
    @Published var watchClipboard: Bool { didSet { persist(.clipboard); configureClipboard() } }
    @Published var showMenuBar: Bool { didSet { persist(.menuBar) } }
    @Published var saveDirectory: URL { didSet { persist(.folder) } }
    @Published var dropActive = false
    @Published var clipboardOffer: String?
    @Published var engineBusy = false
    @Published var engineStatus = "Not checked yet"
    @Published var ytDlpVersion = "—"
    @Published var denoVersion = "—"
    @Published var ffmpegVersion = "—"

    private enum Key: String {
        case container, quality, maxSize, maxSizeMB, clipboard, menuBar, folder
    }

    private let defaults = UserDefaults.standard
    private let engine = EngineStore.shared
    private let service = DownloadService()
    private let clipboard = ClipboardMonitor()
    private var restoring = true
    private var info: VideoInfo?
    private var plan: DownloadPlan?
    private var thumbnail: NSImage?
    private var work: Task<Void, Never>?
    private var thumbTask: Task<Void, Never>?
    private var cookies = SafariCookieChoice()
    private var retriedEngine = false
    private var generation = 0
    private var started = false
    private var maxSizeMB = 25

    private init() {
        let storedContainer = defaults.string(forKey: Key.container.rawValue).flatMap(ContainerFormat.init(rawValue:)) ?? .mp4H264
        let storedQuality = defaults.string(forKey: Key.quality.rawValue).flatMap(Quality.init(rawValue:)) ?? .best
        container = storedContainer
        quality = storedQuality
        let storedMaxSize = defaults.object(forKey: Key.maxSize.rawValue) as? Bool ?? false
        let storedMaxMB = defaults.object(forKey: Key.maxSizeMB.rawValue) as? Int ?? 25
        maxSizeEnabled = storedMaxSize
        maxSizeMB = storedMaxMB
        maxSizeText = storedMaxSize ? String(storedMaxMB) : ""
        let storedClipboard = defaults.object(forKey: Key.clipboard.rawValue) as? Bool ?? false
        let storedMenu = defaults.object(forKey: Key.menuBar.rawValue) as? Bool ?? true
        // Launch measurement turns these on in memory only. didSet does not run
        // during init, so Kevin's saved settings stay as they were.
        watchClipboard = AppFlags.launchSample ? true : storedClipboard
        showMenuBar = AppFlags.launchSample ? true : storedMenu
        if let path = defaults.string(forKey: Key.folder.rawValue) {
            saveDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            saveDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        }
        restoring = false
        clipboard.onURL = { [weak self] url in
            Task { @MainActor in self?.offerClipboard(url) }
        }
    }

    var saveName: String {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if saveDirectory.standardizedFileURL.path == downloads?.standardizedFileURL.path { return "Downloads" }
        return saveDirectory.lastPathComponent
    }

    var engineSummary: String {
        "yt-dlp \(ytDlpVersion) · \(engineStatus)"
    }

    var menuStatus: String {
        switch phase {
        case .empty: return "Paste a video link."
        case .resolving(let message): return message
        case .preview(let preview): return preview.title
        case .downloading(_, let progress): return progress.stage
        case .completed(let completed): return "Saved \(completed.filename)"
        case .failed(let problem): return problem.title
        }
    }

    func start() {
        guard !started else { return }
        started = true
        configureClipboard()
        Task(priority: .utility) {
            await prepareEngine()
            if !AppFlags.launchSample {
                await engine.maybeDailyUpdate()
            }
            await refreshVersions()
        }
    }

    func submit() { resolveNow() }

    func clear() {
        urlText = ""
        info = nil
        plan = nil
        thumbnail = nil
        cookies.clear()
        phase = .empty
        work?.cancel()
        service.cancel()
    }

    func noteTyping() {
        guard !isDownloading else { return }
        generation += 1
        let token = generation
        cookies.clear()
        clipboardOffer = nil
        if urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            info = nil
            plan = nil
            if case .completed = phase { return }
            phase = .empty
            return
        }
        work?.cancel()
        work = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            await self?.resolve(token: token)
        }
    }

    func refreshPlan() {
        guard let info, var input = selectionInput(info) else { return }
        input.maxBytes = currentCap
        guard let plan = FormatSelector.plan(input) else { return }
        self.plan = plan
        if case .preview = phase {
            phase = .preview(previewContent(info, plan: plan))
        }
    }

    func download() {
        guard let info, !isDownloading else { return }
        let urlString = urlText
        guard case .success(let url) = URLValidator.validate(urlString) else { return }
        work?.cancel()
        service.cancel()
        let cap = currentCap
        let container = self.container
        let quality = self.quality
        let useCookies = cookies.takeForDownload()
        let directory = saveDirectory
        phase = .downloading(
            previewContent(info, plan: plan),
            ProgressContent(fraction: 0, headline: cap == nil ? "Downloading" : "Fitting to \(maxSizeMB) MB", stage: "Starting", trailing: "")
        )
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await service.download(
                    url: url,
                    info: info,
                    container: container,
                    quality: quality,
                    maxBytes: cap,
                    outputDirectory: directory,
                    cookiesFromBrowser: useCookies ? "safari" : nil
                ) { update in
                    Task { @MainActor in self.apply(update, cap: cap) }
                }
                if Task.isCancelled { return }
                self.phase = .completed(self.completedContent(outcome, cap: cap))
                self.urlText = ""
                self.retriedEngine = false
            } catch let failure as EngineFailure {
                await self.handle(failure, duringDownload: true)
            } catch is CancellationError {
                self.restorePreview()
            } catch {
                self.phase = .failed(ProblemCopy.present(MappedError(kind: .generic, detail: ""), site: info.siteName, link: urlString))
            }
        }
    }

    func cancelDownload() {
        service.cancel()
        work?.cancel()
        restorePreview()
    }

    func primaryAction() {
        guard case .failed(let problem) = phase else { return }
        switch problem.primary {
        case .safari:
            cookies.arm()
            if info == nil { resolveNow() } else { download() }
        case .update:
            Task { await updateAndRetry() }
        case .fullDiskAccess:
            openFullDiskAccess()
        default:
            break
        }
    }

    private func openFullDiskAccess() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        ]
        for raw in urls {
            guard let url = URL(string: raw) else { continue }
            if NSWorkspace.shared.open(url) { return }
        }
    }

    func secondaryAction() {
        if info == nil { resolveNow() } else { download() }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func revealCompleted() {
        if case .completed(let completed) = phase, let url = completed.fileURL {
            reveal(url)
        }
    }

    func openCompleted() {
        if case .completed(let completed) = phase, let url = completed.fileURL {
            open(url)
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = saveDirectory
        if panel.runModal() == .OK, let url = panel.url {
            saveDirectory = url
        }
    }

    func revealSaveFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([saveDirectory])
    }

    func checkEngineNow() {
        Task { await performEngineUpdate(channel: "stable") }
    }

    func updateEngine(channel: String) {
        Task { await performEngineUpdate(channel: channel) }
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier("public.url") {
            provider.loadItem(forTypeIdentifier: "public.url", options: nil) { item, _ in
                let text: String?
                if let url = item as? URL { text = url.absoluteString }
                else if let data = item as? Data { text = String(data: data, encoding: .utf8) }
                else { text = nil }
                guard let text else { return }
                Task { @MainActor in
                    self.urlText = text
                    self.resolveNow()
                }
            }
            return true
        }
        provider.loadItem(forTypeIdentifier: "public.plain-text", options: nil) { item, _ in
            let text = item as? String
            guard let text else { return }
            Task { @MainActor in
                self.urlText = text
                self.resolveNow()
            }
        }
        return true
    }

    // MARK: - Resolve

    private func resolveNow() {
        generation += 1
        let token = generation
        work?.cancel()
        work = Task { [weak self] in await self?.resolve(token: token) }
    }

    private func resolve(token: Int) async {
        let raw = urlText
        guard case .success(let url) = URLValidator.validate(raw) else {
            if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, token == generation {
                phase = .failed(ProblemCopy.present(MappedError(kind: .unsupported, detail: ""), site: "This link", link: raw))
            }
            return
        }
        guard !isDownloading else { return }
        phase = .resolving("Fetching the video…")
        do {
            _ = try await engine.binaries()
        } catch {
            phase = .failed(PresentedProblem(
                title: "The download engine isn't installed",
                message: "Fetch couldn't find a verified copy of yt-dlp. Reinstall the app.",
                detail: "",
                primaryTitle: nil,
                primary: nil,
                secondaryTitle: nil,
                secondary: nil
            ))
            return
        }
        if token != generation { return }
        let useCookies = cookies.allowsInfoFetch()
        do {
            let info = try await service.fetchInfo(url: url, cookiesFromBrowser: useCookies ? "safari" : nil)
            if token != generation || Task.isCancelled { return }
            guard let plan = FormatSelector.plan(selectionInput(info) ?? SelectionInput(extractorKey: info.extractorKey, duration: info.duration, formats: info.formats, container: container, quality: quality, maxBytes: currentCap)) else {
                phase = .failed(ProblemCopy.present(MappedError(kind: .noFormats, detail: ""), site: info.siteName, link: raw))
                return
            }
            self.info = info
            self.plan = plan
            self.thumbnail = nil
            self.retriedEngine = false
            phase = .preview(previewContent(info, plan: plan))
            loadThumbnail(info)
        } catch let failure as EngineFailure {
            if token != generation { return }
            await handle(failure, duringDownload: false)
        } catch {
            if token != generation { return }
            phase = .failed(ProblemCopy.present(MappedError(kind: .generic, detail: ""), site: "The site", link: raw))
        }
    }

    private func handle(_ failure: EngineFailure, duringDownload: Bool) async {
        if failure.mapped.kind == .cancelled {
            restorePreview()
            return
        }
        if failure.mapped.suggestsEngineUpdate && !retriedEngine && !AppFlags.skipEngineUpdate {
            retriedEngine = true
            phase = .resolving("Updating the engine and trying again…")
            do {
                _ = try await engine.update(channel: "nightly")
                await refreshVersions()
                if duringDownload { download() } else { resolveNow() }
                return
            } catch {
                phase = .failed(ProblemCopy.present(failure.mapped, site: info?.siteName ?? "The site", link: urlText))
                return
            }
        }
        phase = .failed(ProblemCopy.present(failure.mapped, site: info?.siteName ?? "The site", link: urlText))
    }

    private func updateAndRetry() async {
        phase = .resolving("Updating the engine…")
        do {
            _ = try await engine.update(channel: "nightly")
            await refreshVersions()
            resolveNow()
        } catch {
            phase = .failed(ProblemCopy.present(MappedError(kind: .engineOutdated, detail: "The update didn't finish."), site: info?.siteName ?? "The site", link: urlText))
        }
    }

    private func performEngineUpdate(channel: String) async {
        engineBusy = true
        defer { engineBusy = false }
        do {
            _ = try await engine.update(channel: channel)
            await refreshVersions()
        } catch {
            engineStatus = "Update didn't finish"
        }
    }

    private func prepareEngine() async {
        do {
            _ = try await engine.prepare()
            await refreshVersions()
        } catch EngineStoreError.unsupportedArchitecture {
            engineStatus = "Apple Silicon only"
            ytDlpVersion = "—"
        } catch {
            engineStatus = "Missing from the app"
            ytDlpVersion = "—"
        }
    }

    private func refreshVersions() async {
        let versions = await engine.currentVersions()
        ytDlpVersion = versions.ytDlp
        denoVersion = versions.deno
        ffmpegVersion = versions.ffmpeg
        engineStatus = versions.status
    }

    // MARK: - Progress and preview

    private var lastProgressPaint = Date.distantPast

    private func apply(_ update: DownloadProgressUpdate, cap: Int?) {
        let now = Date()
        if now.timeIntervalSince(lastProgressPaint) < 0.12, (update.fraction ?? 0) < 0.999, update.stageIsSteady {
            return
        }
        lastProgressPaint = now
        guard case .downloading(let preview, _) = phase else { return }
        let fraction = update.fraction ?? 0
        let headline = cap == nil ? "Downloading" : "Fitting to \(maxSizeMB) MB"
        let stage: String
        switch update.stage {
        case .preparing: stage = "Getting ready"
        case .downloading: stage = "Downloading"
        case .merging: stage = "Merging video and audio"
        case .encoding(_, let hardware):
            stage = hardware ? "Encoding · pass 2 of 2 · Apple hardware encoder" : "Encoding · pass 2 of 2"
        case .verifying: stage = "Checking the file"
        }
        var trailing = "\(Int((fraction * 100).rounded()))%"
        if let eta = update.eta, eta > 0, eta < 60 * 60 * 6 {
            trailing += " · \(Int(eta.rounded())) s left"
        }
        phase = .downloading(preview, ProgressContent(fraction: fraction, headline: headline, stage: stage, trailing: trailing))
    }

    private func previewContent(_ info: VideoInfo, plan: DownloadPlan?) -> PreviewContent {
        let plan = plan ?? self.plan
        var badges: [PreviewBadge] = []
        if plan?.noWatermark == true {
            badges.append(PreviewBadge(id: "clean", text: "No watermark", good: true))
        }
        if let bytes = plan?.estimatedBytes {
            badges.append(PreviewBadge(id: "size", text: ByteFormatting.approximate(bytes), good: false))
        } else if maxSizeEnabled {
            badges.append(PreviewBadge(id: "cap", text: "≤ \(maxSizeMB) MB", good: false))
        }
        let codec = [plan?.vcodecLabel ?? "", plan?.acodecLabel ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        if !codec.isEmpty {
            badges.append(PreviewBadge(id: "codec", text: codec, good: false))
        }
        let width = plan?.width ?? info.width
        let height = plan?.height ?? info.height
        return PreviewContent(
            title: info.title,
            site: info.siteName,
            author: info.authorLine,
            resolution: ByteFormatting.resolution(width: width, height: height),
            duration: ByteFormatting.duration(info.duration ?? 0),
            thumbnail: thumbnail,
            portrait: (height ?? 0) > (width ?? 0),
            badges: badges
        )
    }

    private func completedContent(_ outcome: DownloadOutcome, cap: Int?) -> CompletedContent {
        var parts = [ByteFormatting.precise(outcome.byteCount)]
        if let height = outcome.height, height > 0 { parts.append("\(height)p") }
        if let codec = outcome.videoCodec.map(CodecLabels.video), !codec.isEmpty { parts.append(codec) }
        if cap != nil {
            parts.append(outcome.underCap ? "fits under \(maxSizeMB) MB" : "over \(maxSizeMB) MB")
        }
        if !outcome.hasAudio && outcome.hasVideo { parts.append("no audio track") }
        return CompletedContent(filename: outcome.fileURL.lastPathComponent, detail: parts.joined(separator: " · "), fileURL: outcome.fileURL)
    }

    private func restorePreview() {
        if let info, let plan {
            phase = .preview(previewContent(info, plan: plan))
        } else {
            phase = .empty
        }
    }

    private func selectionInput(_ info: VideoInfo) -> SelectionInput? {
        SelectionInput(
            extractorKey: info.extractorKey ?? info.extractor,
            duration: info.duration,
            formats: info.formats,
            container: container,
            quality: quality,
            maxBytes: currentCap,
            sourceWidth: info.width,
            sourceHeight: info.height
        )
    }

    private var currentCap: Int? {
        guard maxSizeEnabled, maxSizeMB > 0 else { return nil }
        return maxSizeMB * 1_000_000
    }

    private var isDownloading: Bool {
        if case .downloading = phase { return true }
        return false
    }

    private func loadThumbnail(_ info: VideoInfo) {
        thumbTask?.cancel()
        guard let url = info.thumbnailURL, url.scheme == "https" else { return }
        thumbTask = Task { [weak self] in
            guard let data = try? await ThumbnailLoader().load(url, limit: 8_000_000),
                  let image = NSImage(data: data),
                  image.size.width > 0, image.size.height > 0,
                  image.size.width * image.size.height <= 4096 * 4096 else { return }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.thumbnail = image
                if let info = self.info, let plan = self.plan, case .preview = self.phase {
                    self.phase = .preview(self.previewContent(info, plan: plan))
                }
            }
        }
    }

    func acceptClipboardOffer() {
        guard let offer = clipboardOffer else { return }
        clipboardOffer = nil
        urlText = offer
        resolveNow()
    }

    func dismissClipboardOffer() {
        clipboardOffer = nil
    }

    private func offerClipboard(_ url: URL) {
        guard watchClipboard, !isDownloading else { return }
        guard URLValidator.isSupportedVideoHost(url) else { return }
        if url.absoluteString == urlText { return }
        clipboardOffer = url.absoluteString
        if !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    private func configureClipboard() {
        if watchClipboard {
            clipboard.start()
        } else {
            clipboard.stop()
            clipboardOffer = nil
        }
    }

    private func clampMaxSize() {
        let digits = maxSizeText.filter(\.isNumber)
        if digits != maxSizeText { maxSizeText = digits; return }
        if let value = Int(digits) {
            let clamped = min(4096, max(1, value))
            if clamped != maxSizeMB {
                maxSizeMB = clamped
                defaults.set(clamped, forKey: Key.maxSizeMB.rawValue)
            }
            refreshPlan()
        }
    }

    private func persist(_ key: Key) {
        guard !restoring else { return }
        switch key {
        case .container: defaults.set(container.rawValue, forKey: key.rawValue)
        case .quality: defaults.set(quality.rawValue, forKey: key.rawValue)
        case .maxSize: defaults.set(maxSizeEnabled, forKey: key.rawValue)
        case .maxSizeMB: defaults.set(maxSizeMB, forKey: key.rawValue)
        case .clipboard: defaults.set(watchClipboard, forKey: key.rawValue)
        case .menuBar: defaults.set(showMenuBar, forKey: key.rawValue)
        case .folder: defaults.set(saveDirectory.path, forKey: key.rawValue)
        }
    }
}

/// Downloads a thumbnail without keeping it in the shared URL cache, and stops once the body exceeds the cap.
private final class ThumbnailLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let state = NSLock()
    private var data = Data()
    private var tooBig = false
    private var continuation: CheckedContinuation<Data?, Error>?
    private var limit = 0

    func load(_ url: URL, limit: Int) async throws -> Data? {
        self.limit = limit
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        state.lock()
        let overflow = self.data.count + data.count > limit
        if !overflow { self.data.append(data) }
        tooBig = tooBig || overflow
        state.unlock()
        if overflow { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        state.lock()
        let payload = data
        let rejected = tooBig
        let continuation = self.continuation
        self.continuation = nil
        state.unlock()
        if rejected {
            continuation?.resume(returning: nil)
            return
        }
        if let http = task.response as? HTTPURLResponse, http.statusCode != 200 {
            continuation?.resume(returning: nil)
            return
        }
        if let error, (error as NSError).code != NSURLErrorCancelled {
            continuation?.resume(throwing: error)
            return
        }
        continuation?.resume(returning: payload)
    }
}

final class ClipboardMonitor {
    var onURL: ((URL) -> Void)?
    private var timer: DispatchSourceTimer?
    private var lastCount = -1

    func start() {
        guard timer == nil else { return }
        lastCount = NSPasteboard.general.changeCount
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.2, repeating: 1.2, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let pasteboard = NSPasteboard.general
            let count = pasteboard.changeCount
            guard count != self.lastCount else { return }
            self.lastCount = count
            guard let text = pasteboard.string(forType: .string) else { return }
            if case .success(let url) = URLValidator.validate(text) {
                self.onURL?(url)
            }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
