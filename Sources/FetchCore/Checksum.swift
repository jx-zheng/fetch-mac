import CryptoKit
import Foundation

public enum Checksum {
    /// Streaming SHA-256, hex encoded. The file is not loaded all at once.
    public static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1024 * 1024)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Parse a `SHA2-256SUMS` line list. Names may be separated by two spaces or an asterisk.
    public static func parseSums(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "*" }).map(String.init)
            guard parts.count >= 2 else { continue }
            let hash = parts[0].lowercased()
            guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { continue }
            let name = parts[1...].joined(separator: " ")
            result[name] = hash
        }
        return result
    }
}
