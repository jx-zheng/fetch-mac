import Foundation

public struct MappedError: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case signIn
        case `private`
        case region
        case engineOutdated
        case unsupported
        case network
        case fullDiskAccess
        case ageRestricted
        case botCheck
        case noFormats
        case cancelled
        case tooLarge
        case generic
    }

    public var kind: Kind
    public var detail: String

    public init(kind: Kind, detail: String) {
        self.kind = kind
        self.detail = detail
    }

    public var suggestsEngineUpdate: Bool {
        kind == .engineOutdated
    }
}

public enum ErrorMapper {
    public static func map(output: String, exitCode: Int32) -> MappedError {
        if exitCode == 0 {
            return MappedError(kind: .generic, detail: "")
        }
        let text = output.replacingOccurrences(of: "\r", with: "\n")
        let lowered = text.lowercased()
        let detail = meaningfulLine(in: text)

        if isCancelled(lowered, exitCode: exitCode) {
            return MappedError(kind: .cancelled, detail: detail)
        }
        if lowered.contains("cookies.binarycookies")
            || lowered.contains("full disk access")
            || (lowered.contains("cookie") && (lowered.contains("operation not permitted") || lowered.contains("permissionerror"))) {
            return MappedError(kind: .fullDiskAccess, detail: detail)
        }
        if contains(lowered, ["this video is private", "private video", "video is private", "account owner has not", "status code: 403"]) && contains(lowered, ["private"]) {
            return MappedError(kind: .private, detail: detail)
        }
        if contains(lowered, ["this video is private", "private video", "video is private", "is private"]) {
            return MappedError(kind: .private, detail: detail)
        }
        if contains(lowered, ["not a bot", "confirm you’re not a bot", "confirm you're not a bot", "sign in to confirm"]) {
            return MappedError(kind: .botCheck, detail: detail)
        }
        if contains(lowered, ["age-restricted", "age restricted", "confirm your age", "inappropriate for some users"]) {
            return MappedError(kind: .ageRestricted, detail: detail)
        }
        if contains(lowered, [
            "login required", "please log in", "please login", "sign in to", "log in to",
            "requested content is not available", "use --cookies", "cookies-from-browser",
            "login_required", "authentication required"
        ]) {
            return MappedError(kind: .signIn, detail: detail)
        }
        if contains(lowered, [
            "not available in your country", "geo restricted", "geo-restricted", "georestricted",
            "blocked it in your country", "video is not available in your", "region blocked",
            "this video is unavailable in your country"
        ]) || (lowered.contains("not available") && lowered.contains("country")) {
            return MappedError(kind: .region, detail: detail)
        }
        if contains(lowered, ["unsupported url", "unsupported url:", "no suitable extractor"]) {
            return MappedError(kind: .unsupported, detail: detail)
        }
        if contains(lowered, [
            "unable to extract", "signature extraction failed", "nsig extraction failed",
            "the extractor is broken", "failed to parse json", "unable to download api page"
        ]) {
            return MappedError(kind: .engineOutdated, detail: detail)
        }
        if contains(lowered, ["no video formats", "requested format is not available", "no formats found"]) {
            return MappedError(kind: .noFormats, detail: detail)
        }
        if contains(lowered, [
            "network is unreachable", "timed out", "timeout", "connection reset",
            "temporary failure in name resolution", "urlopen error", "connection refused",
            "nodename nor servname", "tls", "certificate verify failed"
        ]) || lowered.contains("http error 5") {
            return MappedError(kind: .network, detail: detail)
        }
        if lowered.contains("exceeds") && lowered.contains("size") {
            return MappedError(kind: .tooLarge, detail: detail)
        }
        return MappedError(kind: .generic, detail: detail)
    }

    public static func cancelled() -> MappedError {
        MappedError(kind: .cancelled, detail: "Cancelled")
    }

    public static func tooLarge(detail: String) -> MappedError {
        MappedError(kind: .tooLarge, detail: detail)
    }

    private static func isCancelled(_ lowered: String, exitCode: Int32) -> Bool {
        if exitCode == 130 || exitCode == 143 { return true }
        return contains(lowered, ["interrupted by the user", "cancelled by user", "canceled by user", "keyboardinterrupt"])
    }

    private static func contains(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    /// A short, single-line detail safe to show in the UI. URLs are dropped so signed links stay out of the window.
    static func meaningfulLine(in text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { line -> String in
            var value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.lowercased().hasPrefix("error:") {
                value = String(value.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            }
            return value
        }
        let preferred = lines.last { line in
            let lowered = line.lowercased()
            return !line.isEmpty
                && !lowered.hasPrefix("fetch\t")
                && !lowered.hasPrefix("[debug]")
                && !lowered.hasPrefix("warning:")
                && lowered != "na"
        } ?? lines.last ?? ""
        var detail = preferred
        while let range = detail.range(of: #"https?://\S+"#, options: .regularExpression) {
            detail.replaceSubrange(range, with: "…")
        }
        if detail.count > 180 {
            detail = String(detail.prefix(180))
        }
        return detail
    }
}
