import Foundation

public struct DownloadProgressSample: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case download(status: String, downloaded: Double?, total: Double?, speed: Double?, eta: Double?)
        case postprocess(status: String)
        case ffmpegTime(seconds: Double)
        case ffmpegEnded
    }

    public var kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }
}

public enum ProgressParser {
    /// Parses one line from the Fetch progress template or from `ffmpeg -progress`.
    public static func parse(line: String) -> DownloadProgressSample? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("FETCH\t") {
            let parts = trimmed.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 7 else { return nil }
            let total = number(parts[3]) ?? number(parts[4])
            return DownloadProgressSample(kind: .download(
                status: parts[1],
                downloaded: number(parts[2]),
                total: total,
                speed: number(parts[5]),
                eta: number(parts[6])
            ))
        }
        if trimmed.hasPrefix("FETCHPP\t") {
            let status = trimmed.split(separator: "\t", omittingEmptySubsequences: false).dropFirst().first.map(String.init) ?? ""
            return DownloadProgressSample(kind: .postprocess(status: status))
        }
        if trimmed.hasPrefix("out_time_us=") {
            let raw = trimmed.dropFirst("out_time_us=".count)
            if let value = Double(raw), value >= 0 {
                return DownloadProgressSample(kind: .ffmpegTime(seconds: value / 1_000_000))
            }
        }
        if trimmed.hasPrefix("out_time_ms=") {
            let raw = trimmed.dropFirst("out_time_ms=".count)
            if let value = Double(raw), value >= 0 {
                // Some ffmpeg builds report microseconds in the field named out_time_ms.
                let seconds = value > 10_000_000 ? value / 1_000_000 : value / 1_000
                return DownloadProgressSample(kind: .ffmpegTime(seconds: seconds))
            }
        }
        if trimmed == "progress=end" {
            return DownloadProgressSample(kind: .ffmpegEnded)
        }
        return nil
    }

    public static func fraction(downloaded: Double?, total: Double?) -> Double? {
        guard let downloaded, let total, total > 0, downloaded.isFinite, total.isFinite else { return nil }
        return min(1, max(0, downloaded / total))
    }

    public static func fraction(seconds: Double, duration: Double) -> Double? {
        guard seconds.isFinite, duration.isFinite, duration > 0 else { return nil }
        return min(1, max(0, seconds / duration))
    }

    private static func number(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "NA" || cleaned == "None" || cleaned.lowercased() == "nan" { return nil }
        guard let value = Double(cleaned), value.isFinite else { return nil }
        return value
    }
}
