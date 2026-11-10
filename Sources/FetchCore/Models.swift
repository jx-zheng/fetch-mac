import Foundation

public enum ContainerFormat: String, Codable, CaseIterable, Sendable, Identifiable {
    case mp4H264
    case mp4HEVC
    case mov
    case webm
    case mkv
    case m4a
    case mp3

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .mp4H264, .mp4HEVC: return "mp4"
        case .mov: return "mov"
        case .webm: return "webm"
        case .mkv: return "mkv"
        case .m4a: return "m4a"
        case .mp3: return "mp3"
        }
    }

    public var title: String {
        switch self {
        case .mp4H264, .mp4HEVC: return "MP4"
        case .mov: return "MOV"
        case .webm: return "WebM"
        case .mkv: return "MKV"
        case .m4a: return "M4A"
        case .mp3: return "MP3"
        }
    }

    /// Secondary label shown beside the title, matching the approved mockup.
    public var subtitle: String? {
        switch self {
        case .mp4H264: return "H.264"
        case .mp4HEVC: return "HEVC"
        default: return nil
        }
    }

    public var menuTitle: String {
        if let subtitle { return "\(title) · \(subtitle)" }
        return title
    }

    public var isAudioOnly: Bool {
        self == .m4a || self == .mp3
    }
}

public enum Quality: String, Codable, CaseIterable, Sendable, Identifiable {
    case best
    case p2160
    case p1080
    case p720
    case p480

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .best: return "Best"
        case .p2160: return "2160p"
        case .p1080: return "1080p"
        case .p720: return "720p"
        case .p480: return "480p"
        }
    }

    /// Tallest frame this quality will accept. Best is uncapped.
    public var maxHeight: Int? {
        switch self {
        case .best: return nil
        case .p2160: return 2160
        case .p1080: return 1080
        case .p720: return 720
        case .p480: return 480
        }
    }
}

public enum WatermarkKind: String, Equatable, Sendable {
    /// A TikTok Direct / play_addr stream, which is the clean copy.
    case clean
    /// The watermarked download_addr copy.
    case watermarked
    /// No watermark distinction, or a format we cannot prove is clean.
    case unknown
}

public struct MediaFormat: Equatable, Sendable, Codable {
    public var formatID: String
    public var ext: String
    public var vcodec: String?
    public var acodec: String?
    public var width: Int?
    public var height: Int?
    public var fps: Double?
    public var filesize: Int?
    public var filesizeApprox: Int?
    public var tbr: Double?
    public var vbr: Double?
    public var abr: Double?
    public var formatNote: String?

    public init(
        formatID: String,
        ext: String,
        vcodec: String? = nil,
        acodec: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        fps: Double? = nil,
        filesize: Int? = nil,
        filesizeApprox: Int? = nil,
        tbr: Double? = nil,
        vbr: Double? = nil,
        abr: Double? = nil,
        formatNote: String? = nil
    ) {
        self.formatID = formatID
        self.ext = ext
        self.vcodec = vcodec
        self.acodec = acodec
        self.width = width
        self.height = height
        self.fps = fps
        self.filesize = filesize
        self.filesizeApprox = filesizeApprox
        self.tbr = tbr
        self.vbr = vbr
        self.abr = abr
        self.formatNote = formatNote
    }

    public var hasVideo: Bool {
        let value = (vcodec ?? "").lowercased()
        if value == "none" { return false }
        if !value.isEmpty { return true }
        return ["mp4", "mov", "mkv", "webm", "m4v", "flv"].contains(ext.lowercased())
    }

    public var hasAudio: Bool {
        let value = (acodec ?? "").lowercased()
        if value == "none" { return false }
        if !value.isEmpty { return true }
        return ["mp4", "mov", "m4a", "m4v", "mkv", "webm", "mp3"].contains(ext.lowercased())
    }

    public var knownBytes: Int? {
        if let filesize, filesize > 0 { return filesize }
        if let filesizeApprox, filesizeApprox > 0 { return filesizeApprox }
        return nil
    }
}

public struct VideoInfo: Equatable, Sendable {
    public var id: String
    public var title: String
    public var uploader: String?
    public var uploaderID: String?
    public var duration: Double?
    public var thumbnailURL: URL?
    public var webpageURL: URL?
    public var extractor: String?
    public var extractorKey: String?
    public var width: Int?
    public var height: Int?
    public var formats: [MediaFormat]

    public init(
        id: String,
        title: String,
        uploader: String? = nil,
        uploaderID: String? = nil,
        duration: Double? = nil,
        thumbnailURL: URL? = nil,
        webpageURL: URL? = nil,
        extractor: String? = nil,
        extractorKey: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        formats: [MediaFormat]
    ) {
        self.id = id
        self.title = title
        self.uploader = uploader
        self.uploaderID = uploaderID
        self.duration = duration
        self.thumbnailURL = thumbnailURL
        self.webpageURL = webpageURL
        self.extractor = extractor
        self.extractorKey = extractorKey
        self.width = width
        self.height = height
        self.formats = formats
    }

    public var siteName: String {
        let key = (extractorKey ?? extractor ?? "").lowercased()
        switch key {
        case let value where value.contains("tiktok"): return "TikTok"
        case let value where value.contains("youtube"): return "YouTube"
        case let value where value.contains("instagram"): return "Instagram"
        case "twitter", "x": return "X"
        case let value where value.contains("twitter"): return "X"
        case let value where value.contains("reddit"): return "Reddit"
        case let value where value.contains("vimeo"): return "Vimeo"
        default:
            if let extractor, !extractor.isEmpty { return extractor }
            return "Video"
        }
    }

    public var authorLine: String? {
        let site = siteName
        if let uploaderID, !uploaderID.isEmpty {
            if site == "TikTok" || site == "Instagram" || site == "X" {
                return uploaderID.hasPrefix("@") ? uploaderID : "@\(uploaderID)"
            }
        }
        if let uploader, !uploader.isEmpty { return uploader }
        if let uploaderID, !uploaderID.isEmpty { return uploaderID }
        return nil
    }

    public var isTikTok: Bool {
        (extractorKey ?? extractor ?? "").lowercased().contains("tiktok")
    }
}

public enum CodecLabels {
    public static func video(_ raw: String?) -> String {
        let value = (raw ?? "").lowercased()
        if value.isEmpty || value == "none" { return "" }
        if value.hasPrefix("avc") || value.hasPrefix("h264") { return "H.264" }
        if value.hasPrefix("hev") || value.hasPrefix("h265") || value.hasPrefix("hvc") { return "HEVC" }
        if value.hasPrefix("vp9") { return "VP9" }
        if value.hasPrefix("vp8") { return "VP8" }
        if value.hasPrefix("av01") || value.hasPrefix("av1") { return "AV1" }
        return raw?.uppercased() ?? ""
    }

    public static func audio(_ raw: String?) -> String {
        let value = (raw ?? "").lowercased()
        if value.isEmpty || value == "none" { return "" }
        if value.contains("mp4a") || value.hasPrefix("aac") { return "AAC" }
        if value.contains("opus") { return "Opus" }
        if value.contains("vorbis") { return "Vorbis" }
        if value.contains("mp3") { return "MP3" }
        return raw?.uppercased() ?? ""
    }

    public static func pair(video: String?, audio: String?) -> String {
        let left = Self.video(video)
        let right = Self.audio(audio)
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        return "\(left) · \(right)"
    }
}

public enum ByteFormatting {
    public static func approximate(_ bytes: Int) -> String {
        "≈ \(precise(bytes))"
    }

    public static func precise(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_000_000
        if mb >= 10 { return String(format: "%.1f MB", mb) }
        if mb >= 0.1 { return String(format: "%.1f MB", mb) }
        let kb = Double(bytes) / 1_000
        if kb >= 10 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f KB", kb)
    }

    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    public static func resolution(width: Int?, height: Int?) -> String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return "\(width) × \(height)"
    }
}
