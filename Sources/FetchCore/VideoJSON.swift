import CoreFoundation
import Foundation

public enum VideoJSONError: Error, Equatable {
    case malformed
}

extension VideoInfo {
    /// Decode yt-dlp's `-J` document. Unknown fields are ignored, and a bad format entry is skipped.
    public static func decode(json data: Data) throws -> VideoInfo {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw VideoJSONError.malformed
        }
        guard let root = object as? [String: Any] else { throw VideoJSONError.malformed }

        let id = string(root["id"]) ?? "video"
        let title = string(root["title"]).flatMap { $0.isEmpty ? nil : $0 } ?? "Video"
        let formats = (root["formats"] as? [Any] ?? []).compactMap { item -> MediaFormat? in
            guard let dict = item as? [String: Any] else { return nil }
            guard let formatID = string(dict["format_id"]), !formatID.isEmpty else { return nil }
            return MediaFormat(
                formatID: formatID,
                ext: string(dict["ext"]) ?? "mp4",
                vcodec: string(dict["vcodec"]),
                acodec: string(dict["acodec"]),
                width: int(dict["width"]),
                height: int(dict["height"]),
                fps: double(dict["fps"]),
                filesize: int(dict["filesize"]),
                filesizeApprox: int(dict["filesize_approx"]),
                tbr: double(dict["tbr"]),
                vbr: double(dict["vbr"]),
                abr: double(dict["abr"]),
                formatNote: string(dict["format_note"])
            )
        }

        let thumbnail = string(root["thumbnail"]).flatMap { URL(string: $0) }.flatMap { url -> URL? in
            guard url.scheme?.lowercased() == "https" else { return nil }
            return url
        }

        return VideoInfo(
            id: id,
            title: title,
            uploader: string(root["uploader"]) ?? string(root["channel"]) ?? string(root["uploader_url"]),
            uploaderID: string(root["uploader_id"]) ?? string(root["channel_id"]),
            duration: double(root["duration"]),
            thumbnailURL: thumbnail,
            webpageURL: string(root["webpage_url"]).flatMap { URL(string: $0) },
            extractor: string(root["extractor"]),
            extractorKey: string(root["extractor_key"]),
            width: int(root["width"]),
            height: int(root["height"]),
            formats: formats
        )
    }
}

private func string(_ value: Any?) -> String? {
    if let text = value as? String { return text }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
}

private func int(_ value: Any?) -> Int? {
    if let number = value as? Int { return number }
    if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
        return number.intValue
    }
    if let text = value as? String, let number = Int(text) { return number }
    if let number = value as? Double { return Int(number) }
    return nil
}

private func double(_ value: Any?) -> Double? {
    if let number = value as? Double { return number }
    if let number = value as? Int { return Double(number) }
    if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
        return number.doubleValue
    }
    if let text = value as? String { return Double(text) }
    return nil
}
