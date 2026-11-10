import Foundation

/// How one `--update-to` result is treated. An unchanged version is success only when yt-dlp exited 0.
public enum EngineUpdateVerdict: Equatable, Sendable {
    case alreadyCurrent
    case rejectedNonZeroExit
    case failed
    case verifyDownloaded
}

public enum EngineUpdateVerdicts {
    public static func judge(exitCode: Int32, versionBefore: String, versionAfter: String?) -> EngineUpdateVerdict {
        if let versionAfter, !versionBefore.isEmpty, versionAfter == versionBefore {
            return exitCode == 0 ? .alreadyCurrent : .rejectedNonZeroExit
        }
        guard exitCode == 0, let versionAfter, !versionAfter.isEmpty else { return .failed }
        return .verifyDownloaded
    }
}

/// Safari cookies are armed for one link: the info fetch keeps them, and the download that follows spends them.
public struct SafariCookieChoice: Equatable, Sendable {
    public private(set) var armed = false

    public init() {}

    public mutating func arm() {
        armed = true
    }

    public mutating func clear() {
        armed = false
    }

    public func allowsInfoFetch() -> Bool {
        armed
    }

    public mutating func takeForDownload() -> Bool {
        let use = armed
        armed = false
        return use
    }
}
