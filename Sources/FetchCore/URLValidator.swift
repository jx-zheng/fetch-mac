import Foundation

public enum URLValidationError: Error, Equatable, Sendable {
    case empty
    case invalid
    case unsupportedScheme
    case missingHost
    case localOrPrivate
    case tooLong
    case hasUserinfo
}

public enum URLValidator {
    public static let maxLength = 2048

    /// Pull the first http(s) URL out of pasted text, dropping trailing punctuation.
    public static func firstURLString(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let pattern = #"https?://[^\s<>"'`]+"#
        guard let range = trimmed.range(of: pattern, options: .regularExpression) else { return nil }
        var raw = String(trimmed[range])
        while let last = raw.last, ".,);]}>\"'".contains(last) {
            raw.removeLast()
        }
        return raw
    }

    /// Hosts Fetch will offer to save. Anything else on the clipboard is ignored.
    public static func isSupportedVideoHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let suffixes = [
            "youtube.com", "youtu.be", "youtube-nocookie.com",
            "tiktok.com", "instagram.com",
            "twitter.com", "x.com",
            "reddit.com", "redd.it",
            "vimeo.com",
        ]
        return suffixes.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    public static func validate(_ text: String) -> Result<URL, URLValidationError> {
        guard let raw = firstURLString(in: text) else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(trimmed.isEmpty ? .empty : .invalid)
        }
        if raw.count > maxLength || text.count > maxLength * 4 { return .failure(.tooLong) }
        if raw.contains("\n") || raw.contains("\r") || raw.contains("\0") { return .failure(.invalid) }

        guard var components = URLComponents(string: raw) else { return .failure(.invalid) }
        let scheme = (components.scheme ?? "").lowercased()
        guard scheme == "http" || scheme == "https" else { return .failure(.unsupportedScheme) }
        guard let host = components.host, !host.isEmpty else { return .failure(.missingHost) }
        if components.user != nil || components.password != nil { return .failure(.hasUserinfo) }
        if isLocalOrPrivate(host) { return .failure(.localOrPrivate) }

        components.scheme = scheme
        guard let url = components.url else { return .failure(.invalid) }
        return .success(url)
    }

    public static func isLocalOrPrivate(_ host: String) -> Bool {
        var name = host.lowercased()
        if name.hasPrefix("[") && name.hasSuffix("]") {
            name = String(name.dropFirst().dropLast())
        }
        if name == "localhost" || name.hasSuffix(".localhost") || name.hasSuffix(".local") || name.hasSuffix(".localdomain") {
            return true
        }
        if name == "0.0.0.0" || name == "::" || name == "::1" { return true }
        if let ipv4 = IPv4Address(name) { return ipv4.isNonPublic }
        if name.contains(":") { return isNonPublicIPv6(name) }
        return false
    }
}

struct IPv4Address {
    var first: UInt8
    var second: UInt8
    var third: UInt8
    var fourth: UInt8

    init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var values: [UInt8] = []
        values.reserveCapacity(4)
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber) else { return nil }
            if part.count > 1, part.hasPrefix("0") { return nil }
            guard let number = Int(part), (0...255).contains(number) else { return nil }
            values.append(UInt8(number))
        }
        first = values[0]
        second = values[1]
        third = values[2]
        fourth = values[3]
    }

    var isNonPublic: Bool {
        if first == 0 || first == 10 || first == 127 { return true }
        if first == 169 && second == 254 { return true }
        if first == 172 && (16...31).contains(second) { return true }
        if first == 192 && second == 168 { return true }
        if first == 100 && (64...127).contains(second) { return true }
        if first == 192 && second == 0 && third == 2 { return true }
        if first == 198 && second == 51 && third == 100 { return true }
        if first == 203 && second == 0 && third == 113 { return true }
        if first >= 224 { return true }
        return false
    }
}

private func isNonPublicIPv6(_ host: String) -> Bool {
    let lowered = host.lowercased()
    if lowered == "::1" || lowered == "::" { return true }
    if lowered.hasPrefix("fe80:") || lowered.hasPrefix("fe8") || lowered.hasPrefix("fe9") || lowered.hasPrefix("fea") || lowered.hasPrefix("feb") {
        return true
    }
    if lowered.hasPrefix("fc") || lowered.hasPrefix("fd") { return true }
    if lowered.hasPrefix("::ffff:") {
        let mapped = String(lowered.dropFirst("::ffff:".count))
        if let ipv4 = IPv4Address(mapped) { return ipv4.isNonPublic }
        return true
    }
    // IPv4-mapped dotted form inside the last hextet isn't worth guessing. Unique-local and link-local are covered.
    return false
}
