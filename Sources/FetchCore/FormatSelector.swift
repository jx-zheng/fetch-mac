import Foundation

public struct TranscodeRecipe: Equatable, Sendable {
    public var videoEncoder: String?
    public var audioEncoder: String
    public var videoBitrateKbps: Int?
    public var audioBitrateKbps: Int
    public var scaleHeight: Int?
    public var hardware: Bool
    public var constrainedBySize: Bool

    public init(
        videoEncoder: String?,
        audioEncoder: String,
        videoBitrateKbps: Int?,
        audioBitrateKbps: Int,
        scaleHeight: Int?,
        hardware: Bool,
        constrainedBySize: Bool
    ) {
        self.videoEncoder = videoEncoder
        self.audioEncoder = audioEncoder
        self.videoBitrateKbps = videoBitrateKbps
        self.audioBitrateKbps = audioBitrateKbps
        self.scaleHeight = scaleHeight
        self.hardware = hardware
        self.constrainedBySize = constrainedBySize
    }

    /// Software encoders used when VideoToolbox refuses the file.
    public var softwareFallback: TranscodeRecipe? {
        guard hardware, let videoEncoder else { return nil }
        var copy = self
        switch videoEncoder {
        case "h264_videotoolbox":
            copy.videoEncoder = "libx264"
        case "hevc_videotoolbox":
            copy.videoEncoder = "libx265"
        default:
            return nil
        }
        copy.hardware = false
        return copy
    }
}

public struct DownloadPlan: Equatable, Sendable {
    public enum Delivery: Equatable, Sendable {
        case streamCopy
        case transcode(TranscodeRecipe)
    }

    public var selector: String
    public var sourceIDs: [String]
    public var delivery: Delivery
    public var noWatermark: Bool
    public var estimatedBytes: Int?
    public var width: Int?
    public var height: Int?
    public var vcodecLabel: String
    public var acodecLabel: String
    public var fileExtension: String

    public init(
        selector: String,
        sourceIDs: [String],
        delivery: Delivery,
        noWatermark: Bool,
        estimatedBytes: Int?,
        width: Int?,
        height: Int?,
        vcodecLabel: String,
        acodecLabel: String,
        fileExtension: String
    ) {
        self.selector = selector
        self.sourceIDs = sourceIDs
        self.delivery = delivery
        self.noWatermark = noWatermark
        self.estimatedBytes = estimatedBytes
        self.width = width
        self.height = height
        self.vcodecLabel = vcodecLabel
        self.acodecLabel = acodecLabel
        self.fileExtension = fileExtension
    }

    public var needsTranscode: Bool {
        if case .transcode = delivery { return true }
        return false
    }
}

public struct SelectionInput: Equatable, Sendable {
    public var extractorKey: String?
    public var duration: Double?
    public var formats: [MediaFormat]
    public var container: ContainerFormat
    public var quality: Quality
    public var maxBytes: Int?
    public var sourceWidth: Int?
    public var sourceHeight: Int?

    public init(
        extractorKey: String?,
        duration: Double?,
        formats: [MediaFormat],
        container: ContainerFormat,
        quality: Quality,
        maxBytes: Int?,
        sourceWidth: Int? = nil,
        sourceHeight: Int? = nil
    ) {
        self.extractorKey = extractorKey
        self.duration = duration
        self.formats = formats
        self.container = container
        self.quality = quality
        self.maxBytes = maxBytes
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
    }
}

public enum FormatSelector {
    /// TikTok is the site where a clean Direct stream and a watermarked download both exist.
    /// The badge is shown only when the chosen format is one of the Direct / play_addr copies.
    public static func watermarkKind(extractorKey: String?, format: MediaFormat) -> WatermarkKind {
        let key = (extractorKey ?? "").lowercased()
        guard key.contains("tiktok") else { return .unknown }
        let note = (format.formatNote ?? "").lowercased()
        let id = format.formatID.lowercased()
        if note.contains("watermark") || id == "download" || id.contains("download_addr") {
            return .watermarked
        }
        if note.contains("direct") || id.contains("play_addr") || id.hasPrefix("h264_") || id.hasPrefix("bytevc1_") {
            return .clean
        }
        return .unknown
    }

    public static func plan(_ input: SelectionInput) -> DownloadPlan? {
        if input.container.isAudioOnly {
            return audioPlan(input)
        }
        return videoPlan(input)
    }

    public static func isSafeFormatID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count < 80 else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" || scalar == "."
        }
    }

    // MARK: - Video

    private struct Candidate {
        var selector: String
        var sourceIDs: [String]
        var video: MediaFormat
        var audio: MediaFormat?
        var bytes: Int?
        var watermark: WatermarkKind
        var score: Int
    }

    private static func videoPlan(_ input: SelectionInput) -> DownloadPlan? {
        let usable = input.formats.filter { isSafeFormatID($0.formatID) }
        if usable.isEmpty, input.formats.contains(where: \.hasVideo) {
            // A direct file sometimes has a URL for a format id. "b" asks yt-dlp for its best format
            // without putting that URL on the -f line.
            return DownloadPlan(
                selector: "b",
                sourceIDs: [],
                delivery: .streamCopy,
                noWatermark: false,
                estimatedBytes: input.formats.compactMap(\.knownBytes).max(),
                width: input.sourceWidth,
                height: input.sourceHeight,
                vcodecLabel: input.container == .mp4HEVC ? "HEVC" : "H.264",
                acodecLabel: "AAC",
                fileExtension: input.container.fileExtension
            )
        }
        let formats = usable
        let audio = bestAudio(in: formats, container: input.container)
        var candidates: [Candidate] = []

        for format in formats where format.hasVideo && passesHeight(format, quality: input.quality) {
            let watermark = watermarkKind(extractorKey: input.extractorKey, format: format)
            if format.hasAudio {
                candidates.append(Candidate(
                    selector: format.formatID,
                    sourceIDs: [format.formatID],
                    video: format,
                    audio: nil,
                    bytes: format.knownBytes,
                    watermark: watermark,
                    score: score(format: format, watermark: watermark, container: input.container, hasSeparateAudio: false)
                ))
            } else if let audio, isSafeFormatID(audio.formatID) {
                let bytes: Int?
                if let videoBytes = format.knownBytes, let audioBytes = audio.knownBytes {
                    bytes = videoBytes + audioBytes
                } else {
                    bytes = nil
                }
                candidates.append(Candidate(
                    selector: "\(format.formatID)+\(audio.formatID)",
                    sourceIDs: [format.formatID, audio.formatID],
                    video: format,
                    audio: audio,
                    bytes: bytes,
                    watermark: watermark,
                    score: score(format: format, watermark: watermark, container: input.container, hasSeparateAudio: true)
                ))
            }
        }

        guard !candidates.isEmpty else { return nil }
        let compatible = candidates.filter { canStreamCopy($0, container: input.container) }
        let pool = compatible.isEmpty ? candidates : compatible
        let ranked = pool.sorted { $0.score > $1.score }
        guard let best = ranked.first else { return nil }

        if let cap = input.maxBytes, cap > 0 {
            if let fit = ranked.first(where: { candidate in
                guard let bytes = candidate.bytes else { return false }
                return SizeFitMath.fits(bytes: bytes, capBytes: cap) && canStreamCopy(candidate, container: input.container)
            }) {
                return makeVideoPlan(fit, input: input, delivery: .streamCopy, estimatedBytes: fit.bytes)
            }
            let source = candidates.sorted { $0.score > $1.score }[0]
            let recipe = recipe(input: input, sourceWidth: source.video.width, sourceHeight: source.video.height, fps: source.video.fps, sourceBitrate: source.video.tbr ?? source.video.vbr)
            return makeVideoPlan(source, input: input, delivery: .transcode(recipe), estimatedBytes: nil)
        }

        if canStreamCopy(best, container: input.container) {
            return makeVideoPlan(best, input: input, delivery: .streamCopy, estimatedBytes: best.bytes)
        }
        let recipe = recipe(input: input, sourceWidth: best.video.width, sourceHeight: best.video.height, fps: best.video.fps, sourceBitrate: best.video.tbr ?? best.video.vbr)
        return makeVideoPlan(best, input: input, delivery: .transcode(recipe), estimatedBytes: best.bytes)
    }

    private static func makeVideoPlan(
        _ candidate: Candidate,
        input: SelectionInput,
        delivery: DownloadPlan.Delivery,
        estimatedBytes: Int?
    ) -> DownloadPlan {
        let labels = labels(for: input.container, delivery: delivery, video: candidate.video, audio: candidate.audio)
        return DownloadPlan(
            selector: candidate.selector,
            sourceIDs: candidate.sourceIDs,
            delivery: delivery,
            noWatermark: candidate.watermark == .clean,
            estimatedBytes: estimatedBytes,
            width: candidate.video.width ?? input.sourceWidth,
            height: candidate.video.height ?? input.sourceHeight,
            vcodecLabel: labels.video,
            acodecLabel: labels.audio,
            fileExtension: input.container.fileExtension
        )
    }

    // MARK: - Audio

    private static func audioPlan(_ input: SelectionInput) -> DownloadPlan? {
        let audios = input.formats.filter { $0.hasAudio && !$0.hasVideo && isSafeFormatID($0.formatID) }
        guard let best = audios.max(by: { audioScore($0, container: input.container) < audioScore($1, container: input.container) }) else {
            return nil
        }
        let underCap = audios.filter { passesBitrate($0, quality: input.quality) }
        if underCap.isEmpty, input.quality.maxBitrateKbps != nil {
            var recipe = recipe(input: input, sourceWidth: nil, sourceHeight: nil, fps: nil, sourceBitrate: nil)
            recipe.audioBitrateKbps = input.quality.maxBitrateKbps ?? recipe.audioBitrateKbps
            recipe.videoEncoder = nil
            return audioDownloadPlan(best, input: input, delivery: .transcode(recipe), estimatedBytes: nil)
        }
        let considered = underCap.isEmpty ? audios : underCap
        let compatible = considered.filter { audioMatches($0, container: input.container) }
        let fallback = considered.max(by: { audioScore($0, container: input.container) < audioScore($1, container: input.container) }) ?? best
        let pool = compatible.isEmpty ? [fallback] : compatible.sorted { audioScore($0, container: input.container) > audioScore($1, container: input.container) }

        if let cap = input.maxBytes, cap > 0 {
            if let fit = pool.first(where: { format in
                guard let bytes = format.knownBytes else { return false }
                return SizeFitMath.fits(bytes: bytes, capBytes: cap) && audioMatches(format, container: input.container)
            }) {
                return audioDownloadPlan(fit, input: input, delivery: .streamCopy, estimatedBytes: fit.knownBytes)
            }
            let recipe = recipe(input: input, sourceWidth: nil, sourceHeight: nil, fps: nil, sourceBitrate: nil)
            return audioDownloadPlan(fallback, input: input, delivery: .transcode(recipe), estimatedBytes: nil)
        }

        if audioMatches(pool[0], container: input.container) {
            return audioDownloadPlan(pool[0], input: input, delivery: .streamCopy, estimatedBytes: pool[0].knownBytes)
        }
        let recipe = recipe(input: input, sourceWidth: nil, sourceHeight: nil, fps: nil, sourceBitrate: nil)
        return audioDownloadPlan(fallback, input: input, delivery: .transcode(recipe), estimatedBytes: fallback.knownBytes)
    }

    private static func audioDownloadPlan(
        _ format: MediaFormat,
        input: SelectionInput,
        delivery: DownloadPlan.Delivery,
        estimatedBytes: Int?
    ) -> DownloadPlan {
        let label = input.container == .mp3 ? "MP3" : "AAC"
        let shown = delivery == .streamCopy ? (CodecLabels.audio(format.acodec).isEmpty ? label : CodecLabels.audio(format.acodec)) : label
        return DownloadPlan(
            selector: format.formatID,
            sourceIDs: [format.formatID],
            delivery: delivery,
            noWatermark: watermarkKind(extractorKey: input.extractorKey, format: format) == .clean,
            estimatedBytes: estimatedBytes,
            width: nil,
            height: nil,
            vcodecLabel: "",
            acodecLabel: shown,
            fileExtension: input.container.fileExtension
        )
    }

    // MARK: - Scoring

    private static func passesBitrate(_ format: MediaFormat, quality: Quality) -> Bool {
        guard let cap = quality.maxBitrateKbps else { return true }
        let bitrate = Int((format.abr ?? format.tbr ?? 0).rounded())
        if bitrate <= 0 { return true }
        return bitrate <= cap + 8
    }

    private static func passesHeight(_ format: MediaFormat, quality: Quality) -> Bool {
        guard let maxHeight = quality.maxHeight else { return true }
        guard let height = format.height else { return true }
        return height <= maxHeight + 16
    }

    private static func score(format: MediaFormat, watermark: WatermarkKind, container: ContainerFormat, hasSeparateAudio: Bool) -> Int {
        let hasAudio = format.hasAudio || hasSeparateAudio
        let tier = preferenceTier(watermark: watermark, h264: isH264(format), hasAudio: hasAudio)
        let height = (format.height ?? 0) * 1_000
        let bitrate = min(Int(format.tbr ?? format.vbr ?? 0), 80_000)
        let codec = codecAffinity(format, container: container) * 200
        return tier * 10_000_000 + height + codec + bitrate
    }

    /// Mirrors yt-dlp's `b[format_note*=Direct][vcodec^=h264]/b[vcodec^=h264]/b`.
    /// A clean Direct H.264 stream wins, then any other H.264 with audio.
    /// Watermarked copies lose to an unknown stream of the same shape, so a
    /// generic "play" format is used before "download" and the badge stays off.
    private static func preferenceTier(watermark: WatermarkKind, h264: Bool, hasAudio: Bool) -> Int {
        if watermark == .clean && h264 && hasAudio { return 7 }
        if watermark == .clean && h264 { return 6 }
        if watermark != .watermarked && h264 && hasAudio { return 5 }
        if h264 && hasAudio { return 4 }
        if watermark == .clean && hasAudio { return 3 }
        if watermark == .clean { return 2 }
        if watermark != .watermarked && hasAudio { return 1 }
        return 0
    }

    private static func codecAffinity(_ format: MediaFormat, container: ContainerFormat) -> Int {
        switch container {
        case .mp4H264, .mov, .mkv:
            return isH264(format) ? 100 : (isHEVC(format) ? 40 : 10)
        case .mp4HEVC:
            return isHEVC(format) ? 100 : (isH264(format) ? 40 : 10)
        case .webm:
            return isWebVideo(format) ? 100 : 10
        case .m4a, .mp3:
            return 0
        }
    }

    private static func bestAudio(in formats: [MediaFormat], container: ContainerFormat) -> MediaFormat? {
        formats
            .filter { $0.hasAudio && !$0.hasVideo && isSafeFormatID($0.formatID) }
            .max { audioScore($0, container: container) < audioScore($1, container: container) }
    }

    private static func audioScore(_ format: MediaFormat, container: ContainerFormat) -> Int {
        let match = audioMatches(format, container: container) ? 1_000_000 : 0
        let bitrate = Int(format.abr ?? format.tbr ?? 0)
        return match + bitrate
    }

    private static func audioMatches(_ format: MediaFormat, container: ContainerFormat) -> Bool {
        switch container {
        case .mp4H264, .mp4HEVC, .mov, .mkv, .m4a:
            return isAAC(format)
        case .webm:
            return isOpusOrVorbis(format)
        case .mp3:
            return isMP3(format)
        }
    }

    private static func canStreamCopy(_ candidate: Candidate, container: ContainerFormat) -> Bool {
        switch container {
        case .mp4H264, .mov:
            guard isH264(candidate.video) else { return false }
            return audioOK(candidate, matches: isAAC)
        case .mp4HEVC:
            guard isHEVC(candidate.video) else { return false }
            return audioOK(candidate, matches: isAAC)
        case .webm:
            guard isWebVideo(candidate.video) else { return false }
            return audioOK(candidate, matches: isOpusOrVorbis)
        case .mkv:
            return true
        case .m4a, .mp3:
            return false
        }
    }

    private static func audioOK(_ candidate: Candidate, matches: (MediaFormat) -> Bool) -> Bool {
        if let audio = candidate.audio { return matches(audio) }
        if candidate.video.hasAudio { return matches(candidate.video) }
        return false
    }

    private static func labels(
        for container: ContainerFormat,
        delivery: DownloadPlan.Delivery,
        video: MediaFormat,
        audio: MediaFormat?
    ) -> (video: String, audio: String) {
        if case .streamCopy = delivery {
            let audioCodec = audio?.acodec ?? video.acodec
            return (CodecLabels.video(video.vcodec), CodecLabels.audio(audioCodec))
        }
        switch container {
        case .mp4H264, .mov, .mkv:
            return ("H.264", "AAC")
        case .mp4HEVC:
            return ("HEVC", "AAC")
        case .webm:
            return ("VP9", "Opus")
        case .m4a:
            return ("", "AAC")
        case .mp3:
            return ("", "MP3")
        }
    }

    private static func recipe(
        input: SelectionInput,
        sourceWidth: Int?,
        sourceHeight: Int?,
        fps: Double?,
        sourceBitrate: Double?
    ) -> TranscodeRecipe {
        let audioOnly = input.container.isAudioOnly
        let duration = input.duration ?? 0
        let audioKbps = input.quality.maxBitrateKbps
            ?? SizeFitMath.audioBitrateKbps(durationSeconds: duration, capBytes: input.maxBytes, audioOnly: audioOnly)
        let constrained = (input.maxBytes ?? 0) > 0
        var videoBitrate: Int?
        var scale: Int?
        if !audioOnly {
            if let cap = input.maxBytes, cap > 0, duration > 0.25 {
                videoBitrate = SizeFitMath.videoBitrateKbps(capBytes: cap, durationSeconds: duration, audioKbps: audioKbps)
                let width = sourceWidth ?? input.sourceWidth ?? 0
                let height = sourceHeight ?? input.sourceHeight ?? 0
                if width > 0, height > 0, let videoBitrate {
                    let scaled = SizeFitMath.scaledHeight(sourceWidth: width, sourceHeight: height, videoKbps: videoBitrate, fps: fps ?? 30)
                    if scaled + 8 < height { scale = scaled }
                }
            } else if let sourceBitrate, sourceBitrate > 0 {
                videoBitrate = max(800, Int(sourceBitrate.rounded()))
            } else {
                videoBitrate = 6_000
            }
        }
        let encoders = encoders(for: input.container)
        return TranscodeRecipe(
            videoEncoder: audioOnly ? nil : encoders.video,
            audioEncoder: encoders.audio,
            videoBitrateKbps: videoBitrate,
            audioBitrateKbps: audioKbps,
            scaleHeight: scale,
            hardware: encoders.hardware,
            constrainedBySize: constrained
        )
    }

    private static func encoders(for container: ContainerFormat) -> (video: String, audio: String, hardware: Bool) {
        switch container {
        case .mp4H264, .mov, .mkv:
            return ("h264_videotoolbox", "aac", true)
        case .mp4HEVC:
            return ("hevc_videotoolbox", "aac", true)
        case .webm:
            return ("libvpx-vp9", "libopus", false)
        case .m4a:
            return ("", "aac", false)
        case .mp3:
            return ("", "libmp3lame", false)
        }
    }

    private static func isH264(_ format: MediaFormat) -> Bool {
        let value = (format.vcodec ?? "").lowercased()
        if value.hasPrefix("avc") || value.hasPrefix("h264") { return true }
        // A direct MP4 with no reported codec is almost always H.264.
        return value.isEmpty && ["mp4", "mov", "m4v"].contains(format.ext.lowercased())
    }

    private static func isHEVC(_ format: MediaFormat) -> Bool {
        let value = (format.vcodec ?? "").lowercased()
        return value.hasPrefix("hev") || value.hasPrefix("h265") || value.hasPrefix("hvc")
    }

    private static func isWebVideo(_ format: MediaFormat) -> Bool {
        let value = (format.vcodec ?? "").lowercased()
        return value.hasPrefix("vp9") || value.hasPrefix("vp8") || value.hasPrefix("av01") || value.hasPrefix("av1")
    }

    private static func isAAC(_ format: MediaFormat) -> Bool {
        let value = (format.acodec ?? "").lowercased()
        if value.hasPrefix("aac") || value.contains("mp4a") { return true }
        return value.isEmpty && ["mp4", "mov", "m4a", "m4v"].contains(format.ext.lowercased())
    }

    private static func isOpusOrVorbis(_ format: MediaFormat) -> Bool {
        let value = (format.acodec ?? "").lowercased()
        return value.contains("opus") || value.contains("vorbis")
    }

    private static func isMP3(_ format: MediaFormat) -> Bool {
        (format.acodec ?? "").lowercased().contains("mp3")
    }
}
