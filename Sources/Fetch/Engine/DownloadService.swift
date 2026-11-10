import FetchCore
import Foundation

struct EngineFailure: Error {
    var mapped: MappedError
}

struct MediaProbe: Equatable, Sendable {
    var hasVideo: Bool
    var hasAudio: Bool
    var duration: Double?
    var videoCodec: String?
    var width: Int?
    var height: Int?
}

struct DownloadOutcome: Sendable {
    var fileURL: URL
    var byteCount: Int
    var transcoded: Bool
    var hardware: Bool
    var noWatermark: Bool
    var hasAudio: Bool
    var hasVideo: Bool
    var width: Int?
    var height: Int?
    var videoCodec: String?
    var underCap: Bool
}

struct DownloadProgressUpdate: Sendable {
    enum Stage: Sendable {
        case preparing
        case downloading
        case merging
        case encoding(attempt: Int, hardware: Bool)
        case verifying
    }

    var stage: Stage
    var fraction: Double?
    var eta: Double?
    var bytesPerSecond: Double?

    var stageIsSteady: Bool {
        switch stage {
        case .downloading, .encoding: return true
        default: return false
        }
    }
}

/// One metadata fetch or one download at a time. Cancel stops the child and its helpers.
final class DownloadService: @unchecked Sendable {
    private let engine: EngineStore
    private let lock = NSLock()
    private var active: ManagedProcess?
    private var cancelled = false

    init(engine: EngineStore = .shared) {
        self.engine = engine
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = active
        lock.unlock()
        process?.stop()
    }

    func fetchInfo(url: URL, cookiesFromBrowser: String?) async throws -> VideoInfo {
        resetCancellation()
        try await rejectPrivateResolution(of: url)
        let binaries = try await engine.binaries()
        var arguments = baseArguments(binaries)
        if let cookiesFromBrowser {
            arguments += ["--cookies-from-browser", cookiesFromBrowser]
        }
        arguments += ["-J", "--", url.absoluteString]
        let result = try await run(binaries.ytDlp, arguments: arguments, directory: binaries.directory, binaries: binaries)
        if result.code != 0 {
            throw EngineFailure(mapped: ErrorMapper.map(output: result.stderr, exitCode: result.code))
        }
        guard let data = extractJSON(from: result.stdout) else {
            throw EngineFailure(mapped: MappedError(kind: .generic, detail: "The site didn't return video details."))
        }
        do {
            return try VideoInfo.decode(json: data)
        } catch {
            throw EngineFailure(mapped: MappedError(kind: .generic, detail: "The video details couldn't be read."))
        }
    }

    func download(
        url: URL,
        info: VideoInfo,
        container: ContainerFormat,
        quality: Quality,
        maxBytes: Int?,
        outputDirectory: URL,
        cookiesFromBrowser: String?,
        onProgress: @escaping @Sendable (DownloadProgressUpdate) -> Void
    ) async throws -> DownloadOutcome {
        try await rejectPrivateResolution(of: url)
        resetCancellation()
        let plan = FormatSelector.plan(SelectionInput(
            extractorKey: info.extractorKey ?? info.extractor,
            duration: info.duration,
            formats: info.formats,
            container: container,
            quality: quality,
            maxBytes: maxBytes,
            sourceWidth: info.width,
            sourceHeight: info.height
        ))
        guard let plan else {
            throw EngineFailure(mapped: MappedError(kind: .noFormats, detail: "No downloadable format was listed."))
        }
        return try await perform(
            url: url,
            info: info,
            plan: plan,
            container: container,
            quality: quality,
            maxBytes: maxBytes,
            outputDirectory: outputDirectory,
            cookiesFromBrowser: cookiesFromBrowser,
            audioRetry: false,
            onProgress: onProgress
        )
    }

    // MARK: - Pipeline

    private func perform(
        url: URL,
        info: VideoInfo,
        plan: DownloadPlan,
        container: ContainerFormat,
        quality: Quality,
        maxBytes: Int?,
        outputDirectory: URL,
        cookiesFromBrowser: String?,
        audioRetry: Bool,
        onProgress: @escaping @Sendable (DownloadProgressUpdate) -> Void
    ) async throws -> DownloadOutcome {
        let binaries = try await engine.binaries()
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        onProgress(DownloadProgressUpdate(stage: .preparing, fraction: nil, eta: nil, bytesPerSecond: nil))
        try throwIfCancelled()
        try await downloadSource(
            url: url,
            plan: plan,
            binaries: binaries,
            directory: temp,
            cookiesFromBrowser: cookiesFromBrowser,
            onProgress: onProgress
        )
        guard let source = largestMediaFile(in: temp) else {
            throw EngineFailure(mapped: MappedError(kind: .generic, detail: "The download finished without a video file."))
        }

        var working = source
        var transcoded = false
        var hardware = false
        if plan.needsTranscode, let cap = maxBytes, fileSize(source) <= cap, !container.isAudioOnly {
            if let remuxed = try await remuxIfNeeded(source: source, container: container, binaries: binaries, directory: temp) {
                working = remuxed
            }
        } else if plan.needsTranscode, case .transcode(let recipe) = plan.delivery {
            onProgress(DownloadProgressUpdate(stage: .encoding(attempt: 1, hardware: recipe.hardware), fraction: 0, eta: nil, bytesPerSecond: nil))
            let encoded = try await encode(
                source: source,
                recipe: recipe,
                container: container,
                maxBytes: maxBytes,
                duration: info.duration,
                binaries: binaries,
                directory: temp,
                onProgress: onProgress
            )
            working = encoded.file
            transcoded = true
            hardware = encoded.hardware
        } else if let remuxed = try await remuxIfNeeded(source: source, container: container, binaries: binaries, directory: temp) {
            working = remuxed
        }

        onProgress(DownloadProgressUpdate(stage: .verifying, fraction: nil, eta: nil, bytesPerSecond: nil))
        let probe = try await probe(working, binaries: binaries)
        if !container.isAudioOnly && !probe.hasVideo {
            throw EngineFailure(mapped: MappedError(kind: .generic, detail: "The file doesn't contain a video track."))
        }
        if !probe.hasAudio && info.isTikTok && !audioRetry {
            let h264 = info.formats.filter { format in
                let codec = (format.vcodec ?? "").lowercased()
                return (codec.hasPrefix("h264") || codec.hasPrefix("avc")) && format.hasAudio && !plan.sourceIDs.contains(format.formatID)
            }
            if let retry = FormatSelector.plan(SelectionInput(
                extractorKey: info.extractorKey ?? info.extractor,
                duration: info.duration,
                formats: h264,
                container: container,
                quality: quality,
                maxBytes: maxBytes,
                sourceWidth: info.width,
                sourceHeight: info.height
            )), retry.selector != plan.selector {
                return try await perform(
                    url: url,
                    info: info,
                    plan: retry,
                    container: container,
                    quality: quality,
                    maxBytes: maxBytes,
                    outputDirectory: outputDirectory,
                    cookiesFromBrowser: cookiesFromBrowser,
                    audioRetry: true,
                    onProgress: onProgress
                )
            }
        }

        let filename = FilenameSanitizer.sanitize(title: info.title, extension: plan.fileExtension)
        guard let destination = uniqueFileURL(directory: outputDirectory, filename: filename) else {
            throw EngineFailure(mapped: MappedError(kind: .generic, detail: "Couldn't choose a safe file name."))
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: working, to: destination)
        let bytes = fileSize(destination)
        let underCap = maxBytes.map { bytes <= $0 } ?? true
        return DownloadOutcome(
            fileURL: destination,
            byteCount: bytes,
            transcoded: transcoded,
            hardware: hardware,
            noWatermark: plan.noWatermark,
            hasAudio: probe.hasAudio,
            hasVideo: probe.hasVideo,
            width: probe.width ?? plan.width,
            height: probe.height ?? plan.height,
            videoCodec: probe.videoCodec,
            underCap: underCap
        )
    }

    private func downloadSource(
        url: URL,
        plan: DownloadPlan,
        binaries: EngineBinaries,
        directory: URL,
        cookiesFromBrowser: String?,
        onProgress: @escaping @Sendable (DownloadProgressUpdate) -> Void
    ) async throws {
        var arguments = baseArguments(binaries)
        arguments += [
            "--progress-template", "download:FETCH\t%(progress.status)s\t%(progress.downloaded_bytes)s\t%(progress.total_bytes)s\t%(progress.total_bytes_estimate)s\t%(progress.speed)s\t%(progress.eta)s",
            "--progress-template", "postprocess:FETCHPP\t%(progress.status)s",
            "-f", plan.selector,
            "-o", "source.%(ext)s",
            "--no-mtime",
        ]
        if plan.selector.contains("+") {
            arguments += ["--merge-output-format", "mkv"]
        }
        if let cookiesFromBrowser {
            arguments += ["--cookies-from-browser", cookiesFromBrowser]
        }
        arguments += ["--", url.absoluteString]
        let result = try await run(binaries.ytDlp, arguments: arguments, directory: directory, binaries: binaries) { line in
            guard let sample = ProgressParser.parse(line: line) else { return }
            switch sample.kind {
            case .download(_, let downloaded, let total, let speed, let eta):
                onProgress(DownloadProgressUpdate(
                    stage: .downloading,
                    fraction: ProgressParser.fraction(downloaded: downloaded, total: total),
                    eta: eta,
                    bytesPerSecond: speed
                ))
            case .postprocess:
                onProgress(DownloadProgressUpdate(stage: .merging, fraction: nil, eta: nil, bytesPerSecond: nil))
            default:
                break
            }
        }
        if result.code != 0 {
            let mapped = ErrorMapper.map(output: result.stderr, exitCode: result.code)
            if mapped.kind == .cancelled || wasCancelled {
                throw EngineFailure(mapped: ErrorMapper.cancelled())
            }
            throw EngineFailure(mapped: mapped)
        }
    }

    private func encode(
        source: URL,
        recipe: TranscodeRecipe,
        container: ContainerFormat,
        maxBytes: Int?,
        duration: Double?,
        binaries: EngineBinaries,
        directory: URL,
        onProgress: @escaping @Sendable (DownloadProgressUpdate) -> Void
    ) async throws -> (file: URL, hardware: Bool) {
        var current = recipe
        var hardware = recipe.hardware
        var attempt = 0
        let limit = 4
        while attempt < limit {
            try throwIfCancelled()
            let output = directory.appendingPathComponent("encoded-\(attempt).\(container.fileExtension)")
            let probeDuration = duration ?? (try await probe(source, binaries: binaries)).duration ?? 0
            let code = try await runFFmpeg(
                binaries: binaries,
                arguments: ffmpegArguments(input: source, output: output, recipe: current, container: container),
                duration: probeDuration,
                attempt: attempt + 1,
                hardware: hardware,
                onProgress: onProgress
            )
            if code != 0 {
                if let fallback = current.softwareFallback {
                    current = fallback
                    hardware = false
                    continue
                }
                throw EngineFailure(mapped: MappedError(kind: .generic, detail: "Encoding failed."))
            }
            let size = fileSize(output)
            if let maxBytes, size > maxBytes, let bitrate = current.videoBitrateKbps, attempt + 1 < limit {
                var smaller = current
                smaller.videoBitrateKbps = SizeFitMath.retryBitrate(previousKbps: bitrate)
                if let height = smaller.scaleHeight {
                    smaller.scaleHeight = max(144, height - height / 8)
                }
                current = smaller
                attempt += 1
                try? FileManager.default.removeItem(at: output)
                continue
            }
            if let maxBytes, size > maxBytes {
                try? FileManager.default.removeItem(at: output)
                throw EngineFailure(mapped: ErrorMapper.tooLarge(detail: "Still \(ByteFormatting.precise(size)) after re-encoding."))
            }
            return (output, hardware)
        }
        throw EngineFailure(mapped: ErrorMapper.tooLarge(detail: "Couldn't fit the video under the size you set."))
    }

    private func runFFmpeg(
        binaries: EngineBinaries,
        arguments: [String],
        duration: Double,
        attempt: Int,
        hardware: Bool,
        onProgress: @escaping @Sendable (DownloadProgressUpdate) -> Void
    ) async throws -> Int32 {
        try await run(binaries.ffmpeg, arguments: arguments, directory: binaries.directory, binaries: binaries) { line in
            guard let sample = ProgressParser.parse(line: line) else { return }
            switch sample.kind {
            case .ffmpegTime(let seconds):
                onProgress(DownloadProgressUpdate(
                    stage: .encoding(attempt: attempt, hardware: hardware),
                    fraction: ProgressParser.fraction(seconds: seconds, duration: duration),
                    eta: nil,
                    bytesPerSecond: nil
                ))
            case .ffmpegEnded:
                onProgress(DownloadProgressUpdate(stage: .encoding(attempt: attempt, hardware: hardware), fraction: 1, eta: nil, bytesPerSecond: nil))
            default:
                break
            }
        }.code
    }

    private func ffmpegArguments(input: URL, output: URL, recipe: TranscodeRecipe, container: ContainerFormat) -> [String] {
        var arguments = ["-hide_banner", "-loglevel", "error", "-nostats", "-nostdin", "-y", "-progress", "pipe:1", "-i", input.path]
        if let video = recipe.videoEncoder {
            arguments += ["-map", "0:v:0", "-map", "0:a:0?", "-c:v", video]
            if let bitrate = recipe.videoBitrateKbps {
                arguments += ["-b:v", "\(bitrate)k", "-maxrate", "\(bitrate)k", "-bufsize", "\(bitrate * 2)k"]
            }
            if video == "libvpx-vp9" {
                arguments += ["-deadline", "realtime", "-cpu-used", "8", "-row-mt", "1"]
            } else if video == "libx264" {
                arguments += ["-preset", "veryfast", "-pix_fmt", "yuv420p"]
            } else if video == "libx265" {
                arguments += ["-preset", "veryfast", "-pix_fmt", "yuv420p"]
            } else if video.contains("videotoolbox") {
                arguments += ["-pix_fmt", "yuv420p", "-allow_sw", "1"]
            }
            if let height = recipe.scaleHeight {
                arguments += ["-vf", "scale=-2:\(height)"]
            }
            arguments += ["-c:a", recipe.audioEncoder, "-b:a", "\(recipe.audioBitrateKbps)k"]
        } else {
            arguments += ["-vn", "-c:a", recipe.audioEncoder, "-b:a", "\(recipe.audioBitrateKbps)k"]
        }
        if container == .mp4H264 || container == .mp4HEVC || container == .mov || container == .m4a {
            arguments += ["-movflags", "+faststart"]
        }
        arguments.append(output.path)
        return arguments
    }

    private func remuxIfNeeded(source: URL, container: ContainerFormat, binaries: EngineBinaries, directory: URL) async throws -> URL? {
        if source.pathExtension.lowercased() == container.fileExtension { return source }
        let output = directory.appendingPathComponent("remux.\(container.fileExtension)")
        let code = try await run(
            binaries.ffmpeg,
            arguments: ["-hide_banner", "-loglevel", "error", "-y", "-i", source.path, "-c", "copy", "-movflags", "+faststart", output.path],
            directory: directory,
            binaries: binaries
        ).code
        guard code == 0 else { return source }
        return output
    }

    func probe(_ file: URL, binaries: EngineBinaries) async throws -> MediaProbe {
        let result = try await run(
            binaries.ffprobe,
            arguments: ["-v", "error", "-show_entries", "stream=codec_type,codec_name,width,height:format=duration", "-of", "json", file.path],
            directory: binaries.directory,
            binaries: binaries
        )
        guard result.code == 0, let data = result.stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return MediaProbe(hasVideo: false, hasAudio: false, duration: nil, videoCodec: nil, width: nil, height: nil)
        }
        let streams = object["streams"] as? [[String: Any]] ?? []
        let video = streams.first { ($0["codec_type"] as? String) == "video" }
        let audio = streams.contains { ($0["codec_type"] as? String) == "audio" }
        let duration = (object["format"] as? [String: Any]).flatMap { value -> Double? in
            if let text = value["duration"] as? String { return Double(text) }
            if let number = value["duration"] as? NSNumber { return number.doubleValue }
            return value["duration"] as? Double
        }
        return MediaProbe(
            hasVideo: video != nil,
            hasAudio: audio,
            duration: duration,
            videoCodec: video?["codec_name"] as? String,
            width: jsonInt(video?["width"]),
            height: jsonInt(video?["height"])
        )
    }

    // MARK: - Process

    private struct RunResult {
        var code: Int32
        var stdout: String
        var stderr: String
    }

    private final class OutputCapture: @unchecked Sendable {
        var onLine: (@Sendable (String) -> Void)?
        private let lock = NSLock()
        private var stdout = ""
        private var stderr: [String] = []

        func append(_ stream: ProcessStream, _ line: String) {
            onLine?(line)
            lock.lock()
            defer { lock.unlock() }
            if stream == .standardOutput {
                if stdout.utf8.count < 32_000_000 {
                    stdout += line
                    stdout += "\n"
                }
            } else if !line.hasPrefix("FETCH") {
                stderr.append(line)
                if stderr.count > 200 { stderr.removeFirst(stderr.count - 200) }
            }
        }

        func result(code: Int32) -> RunResult {
            lock.lock()
            defer { lock.unlock() }
            return RunResult(code: code, stdout: stdout, stderr: stderr.joined(separator: "\n"))
        }
    }

    private func run(
        _ executable: URL,
        arguments: [String],
        directory: URL,
        binaries: EngineBinaries,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> RunResult {
        try throwIfCancelled()
        let runner = ManagedProcess()
        lock.lock()
        active = runner
        lock.unlock()
        defer {
            lock.lock()
            if active === runner { active = nil }
            lock.unlock()
        }
        let capture = OutputCapture()
        capture.onLine = onLine
        let code = try await runner.run(
            executable: executable,
            arguments: arguments,
            environment: ChildEnvironment.make(binDirectory: binaries.directory),
            currentDirectory: directory,
            onLine: { stream, line in capture.append(stream, line) }
        )
        return capture.result(code: code)
    }

    private func baseArguments(_ binaries: EngineBinaries) -> [String] {
        [
            "--ignore-config",
            "--no-playlist",
            "--no-warnings",
            "--no-update",
            "--newline",
            "--retries", "3",
            "--socket-timeout", "30",
            "--js-runtimes", "deno:\(binaries.deno.path)",
            "--ffmpeg-location", binaries.directory.path,
            "--remote-components", "ejs:github",
            "--remote-components", "ejs:npm",
        ]
    }

    private func rejectPrivateResolution(of url: URL) async throws {
        guard let host = url.host, !host.isEmpty else { return }
        if URLValidator.isLocalOrPrivate(host) {
            throw EngineFailure(mapped: MappedError(kind: .unsupported, detail: "That address isn't a public video link."))
        }
        let addresses = await DNSLookup.addresses(for: host)
        guard !addresses.isEmpty else { return }
        if addresses.allSatisfy({ URLValidator.isLocalOrPrivate($0) }) {
            throw EngineFailure(mapped: MappedError(kind: .unsupported, detail: "That address isn't a public video link."))
        }
    }

    private func resetCancellation() {
        lock.lock()
        cancelled = false
        lock.unlock()
    }

    private var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func throwIfCancelled() throws {
        if wasCancelled { throw EngineFailure(mapped: ErrorMapper.cancelled()) }
    }

    private func makeTempDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("Fetch/tmp/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func largestMediaFile(in directory: URL) -> URL? {
        let allowed: Set<String> = ["mp4", "mkv", "webm", "mov", "m4a", "mp3", "opus", "ogg", "aac", "m4v"]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files
            .filter { allowed.contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.hasPrefix(".") }
            .max { fileSize($0) < fileSize($1) }
    }

    private func fileSize(_ url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }

    private func uniqueFileURL(directory: URL, filename: String) -> URL? {
        if case .success(let url) = OutputPath.fileURL(directory: directory, filename: filename),
           !FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let ext = (filename as NSString).pathExtension
        var stem = (filename as NSString).deletingPathExtension
        if stem.isEmpty { stem = "Video" }
        for index in 2...99 {
            let candidate = "\(stem) \(index).\(ext)"
            if case .success(let url) = OutputPath.fileURL(directory: directory, filename: candidate),
               !FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private func jsonInt(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private func extractJSON(from text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return nil }
        let slice = text[start...end]
        return Data(slice.utf8)
    }
}

/// Visible to the engine without pulling the UI in. Set before the app starts.
enum AppFlags {
    static var idleBenchmark = false
    static var skipEngineUpdate = ProcessInfo.processInfo.environment["FETCH_SKIP_UPDATE"] == "1"
}
