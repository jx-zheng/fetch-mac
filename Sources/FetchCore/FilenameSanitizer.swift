import Foundation

public enum FilenameSanitizer {
    public static let allowedExtensions: Set<String> = ["mp4", "mov", "webm", "mkv", "m4a", "mp3"]
    public static let maxStemLength = 180

    public static func sanitize(title: String, extension ext: String) -> String {
        let safeExt = safeExtension(ext)
        var stem = cleanedStem(title)
        if stem.isEmpty { stem = "Video" }
        if stem.count > maxStemLength {
            let end = stem.index(stem.startIndex, offsetBy: maxStemLength)
            stem = String(stem[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if stem.isEmpty { stem = "Video" }
        }
        return "\(stem).\(safeExt)"
    }

    public static func safeExtension(_ ext: String) -> String {
        let trimmed = ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". \t"))
        let stem = trimmed.split(separator: ".").last.map(String.init) ?? trimmed
        return allowedExtensions.contains(stem) ? stem : "mp4"
    }

    private static func cleanedStem(_ title: String) -> String {
        var scalars: [Character] = []
        for character in title {
            for scalar in character.unicodeScalars {
                if scalar.value < 32 || scalar.value == 0x7F { continue }
                if (0x202A...0x202E).contains(scalar.value) { continue }
                if (0x2066...0x2069).contains(scalar.value) { continue }
                let ch = Character(scalar)
                if ch == "/" || ch == "\\" || ch == ":" || ch == "|" || ch == "\0" {
                    scalars.append(" ")
                } else {
                    scalars.append(ch)
                }
            }
        }
        var stem = String(scalars)
        stem = stem.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        while stem.hasPrefix(".") || stem.hasPrefix(" ") {
            stem.removeFirst()
        }
        while stem.contains("..") {
            stem = stem.replacingOccurrences(of: "..", with: ".")
        }
        while stem.hasSuffix(".") || stem.hasSuffix(" ") {
            stem.removeLast()
        }
        return stem
    }
}

public enum OutputPathError: Error, Equatable, Sendable {
    case emptyName
    case escaped
}

public enum OutputPath {
    /// Build a file URL that is a direct child of `directory`. Rejects names that could escape it.
    public static func fileURL(directory: URL, filename: String) -> Result<URL, OutputPathError> {
        let name = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." { return .failure(.emptyName) }
        if name.contains("/") || name.contains("\\") || name.contains("\0") || name.contains(":") {
            return .failure(.escaped)
        }
        let directory = directory.standardizedFileURL
        let file = directory.appendingPathComponent(name, isDirectory: false).standardizedFileURL
        let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        guard file.path.hasPrefix(prefix) else { return .failure(.escaped) }
        guard file.lastPathComponent == name else { return .failure(.escaped) }
        return .success(file)
    }
}
