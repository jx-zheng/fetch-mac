import Darwin
import FetchCore
import Foundation

struct EngineBinaries: Sendable {
    var directory: URL
    var ytDlp: URL
    var ffmpeg: URL
    var ffprobe: URL
    var deno: URL
}

struct EngineVersions: Equatable, Sendable {
    var ytDlp: String
    var deno: String
    var ffmpeg: String
    var checkedAt: Date?
    var upToDate: Bool
    var status: String
}

struct EngineManifest: Decodable, Sendable {
    var ytDlpVersion: String
    var denoVersion: String
    var ffmpegVersion: String
    var binaries: [String: [String: String]]
}

enum EngineStoreError: Error {
    case missingBundle
    case checksumMismatch(String)
    case updateFailed(String)
    case unsupportedArchitecture
}

actor EngineStore {
    static let shared = EngineStore()

    private var cached: EngineBinaries?
    private var versions = EngineVersions(ytDlp: "—", deno: "—", ffmpeg: "—", checkedAt: nil, upToDate: false, status: "Not checked yet")
    private var updateTask: Task<String, Error>?
    private var hashCache: [String: HashRecord] = [:]
    private var hashCacheLoaded = false
    private let fileManager = FileManager.default

    func currentVersions() -> EngineVersions { versions }

    func prepare() async throws -> EngineBinaries {
        if let cached { return cached }
        let binaries = try installFromBundle(replacingSelfUpdate: false)
        cached = binaries
        versions.ytDlp = readSidecar(named: "yt-dlp.version") ?? bundledManifest()?.ytDlpVersion ?? versions.ytDlp
        versions.deno = bundledManifest()?.denoVersion ?? versions.deno
        versions.ffmpeg = bundledManifest()?.ffmpegVersion ?? versions.ffmpeg
        versions.status = "Ready"
        return binaries
    }

    func binaries() async throws -> EngineBinaries {
        if let cached { return cached }
        return try await prepare()
    }

    func maybeDailyUpdate() async {
        guard !AppFlags.skipEngineUpdate else { return }
        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: "lastEngineCheck") as? Date
        if let last, Date().timeIntervalSince(last) < 20 * 60 * 60 {
            versions.checkedAt = last
            versions.upToDate = true
            versions.status = checkedPhrase(last)
            return
        }
        let channel = rememberedChannel()
        do {
            _ = try await update(channel: channel)
        } catch {
            versions.status = "Couldn't check for an update"
        }
    }

    @discardableResult
    func update(channel: String) async throws -> String {
        let chosen = (channel == "nightly") ? "nightly" : "stable"
        while let existing = updateTask {
            _ = try? await existing.value
        }
        let task = Task { try await self.performUpdate(channel: chosen) }
        updateTask = task
        defer { updateTask = nil }
        return try await task.value
    }

    private func performUpdate(channel: String) async throws -> String {
        let binaries = try await prepare()
        let before = (try? await readVersion(binaries.ytDlp)) ?? readSidecar(named: "yt-dlp.version") ?? ""
        let backup = binaries.ytDlp.appendingPathExtension("bak")
        try? fileManager.removeItem(at: backup)
        try fileManager.copyItem(at: binaries.ytDlp, to: backup)
        let runner = ManagedProcess()
        let code = try await runner.run(
            executable: binaries.ytDlp,
            arguments: ["--ignore-config", "--update-to", "\(channel)@latest"],
            environment: ChildEnvironment.make(binDirectory: binaries.directory),
            currentDirectory: binaries.directory,
            onLine: { _, _ in }
        )
        let after = try? await readVersion(binaries.ytDlp)
        switch EngineUpdateVerdicts.judge(exitCode: code, versionBefore: before, versionAfter: after) {
        case .alreadyCurrent:
            try? fileManager.removeItem(at: backup)
            noteUpdate(version: after ?? before, channel: channel)
            return after ?? before
        case .rejectedNonZeroExit, .failed:
            try? restore(backup, over: binaries.ytDlp)
            throw EngineStoreError.updateFailed("The engine update didn't finish (exit \(code)).")
        case .verifyDownloaded:
            break
        }
        guard let after else {
            try? restore(backup, over: binaries.ytDlp)
            throw EngineStoreError.updateFailed("The engine update didn't finish (exit \(code)).")
        }
        do {
            let digest = try Checksum.sha256Hex(of: binaries.ytDlp)
            try await verifyPublishedSum(digest, channel: channel)
            try writeSidecar(digest, named: "yt-dlp.sha256")
            try writeSidecar(digest, named: "yt-dlp.upstream.sha256")
        } catch {
            try? restore(backup, over: binaries.ytDlp)
            cached = nil
            throw error
        }
        try? fileManager.removeItem(at: backup)
        removeQuarantine(binaries.ytDlp)
        if let installed = readSidecar(named: "yt-dlp.sha256") {
            rememberHash(of: binaries.ytDlp, sha256: installed)
        }
        try writeSidecar(after, named: "yt-dlp.version")
        cached = binaries
        noteUpdate(version: after, channel: channel)
        return after
    }

    private func noteUpdate(version: String, channel: String) {
        let now = Date()
        let defaults = UserDefaults.standard
        defaults.set(now, forKey: "lastEngineCheck")
        defaults.set(channel, forKey: "engineChannel")
        versions.ytDlp = version
        versions.checkedAt = now
        versions.upToDate = true
        versions.status = checkedPhrase(now)
    }

    private func rememberedChannel() -> String {
        UserDefaults.standard.string(forKey: "engineChannel") == "nightly" ? "nightly" : "stable"
    }

    // MARK: - Install

    private func installFromBundle(replacingSelfUpdate: Bool) throws -> EngineBinaries {
        guard let manifest = bundledManifest(), let resourceBin = bundledBinRoot() else {
            throw EngineStoreError.missingBundle
        }
        let support = try supportBinDirectory()
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path)

        let arch = currentArch()
        guard arch == "arm64" else { throw EngineStoreError.unsupportedArchitecture }
        try installStatic(
            name: "ffmpeg",
            source: resourceBin.appendingPathComponent(arch).appendingPathComponent("ffmpeg"),
            destination: support.appendingPathComponent("ffmpeg"),
            expected: manifest.binaries["ffmpeg"]?[arch]
        )
        try installStatic(
            name: "ffprobe",
            source: resourceBin.appendingPathComponent(arch).appendingPathComponent("ffprobe"),
            destination: support.appendingPathComponent("ffprobe"),
            expected: manifest.binaries["ffprobe"]?[arch]
        )
        try installStatic(
            name: "deno",
            source: resourceBin.appendingPathComponent(arch).appendingPathComponent("deno"),
            destination: support.appendingPathComponent("deno"),
            expected: manifest.binaries["deno"]?[arch]
        )
        try installYTDLP(
            source: resourceBin.appendingPathComponent("yt-dlp"),
            destination: support.appendingPathComponent("yt-dlp"),
            expected: manifest.binaries["yt-dlp"]?["signed"] ?? manifest.binaries["yt-dlp"]?["universal"],
            bundledVersion: manifest.ytDlpVersion,
            forceBundle: replacingSelfUpdate
        )
        return EngineBinaries(
            directory: support,
            ytDlp: support.appendingPathComponent("yt-dlp"),
            ffmpeg: support.appendingPathComponent("ffmpeg"),
            ffprobe: support.appendingPathComponent("ffprobe"),
            deno: support.appendingPathComponent("deno")
        )
    }

    private func installStatic(name: String, source: URL, destination: URL, expected: String?) throws {
        guard let expected else { throw EngineStoreError.checksumMismatch(name) }
        let wanted = expected.lowercased()
        let sourceHash = try cachedHash(of: source)
        guard sourceHash == wanted else { throw EngineStoreError.checksumMismatch(name) }
        if fileManager.fileExists(atPath: destination.path) {
            let current = try cachedHash(of: destination)
            if current == wanted {
                removeQuarantine(destination)
                return
            }
            try? fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        removeQuarantine(destination)
        let copied = try cachedHash(of: destination)
        guard copied == wanted else {
            try? fileManager.removeItem(at: destination)
            throw EngineStoreError.checksumMismatch(name)
        }
        try writeSidecar(copied, named: "\(name).sha256")
    }

    private func installYTDLP(source: URL, destination: URL, expected: String?, bundledVersion: String, forceBundle: Bool) throws {
        guard let expected else { throw EngineStoreError.checksumMismatch("yt-dlp") }
        let wanted = expected.lowercased()
        let sourceHash = try cachedHash(of: source)
        guard sourceHash == wanted else { throw EngineStoreError.checksumMismatch("yt-dlp") }

        if !forceBundle, fileManager.fileExists(atPath: destination.path),
           let sidecar = readSidecar(named: "yt-dlp.sha256") {
            let current = try cachedHash(of: destination)
            if current == sidecar.lowercased() {
                removeQuarantine(destination)
                return
            }
        }

        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        removeQuarantine(destination)
        let copied = try cachedHash(of: destination)
        guard copied == wanted else {
            try? fileManager.removeItem(at: destination)
            throw EngineStoreError.checksumMismatch("yt-dlp")
        }
        try writeSidecar(copied, named: "yt-dlp.sha256")
        try writeSidecar(bundledVersion, named: "yt-dlp.version")
    }

    // MARK: - Identity cache

    private func cachedHash(of url: URL) throws -> String {
        try loadHashCache()
        let stamp = try fileStamp(url)
        if let hit = hashCache[url.path],
           hit.path == stamp.path, hit.size == stamp.size, hit.mtime == stamp.mtime, hit.inode == stamp.inode {
            return hit.sha256
        }
        let digest = try Checksum.sha256Hex(of: url)
        rememberHash(of: url, sha256: digest, stamp: stamp)
        return digest
    }

    private func rememberHash(of url: URL, sha256: String) {
        guard let stamp = try? fileStamp(url) else { return }
        rememberHash(of: url, sha256: sha256, stamp: stamp)
    }

    private func rememberHash(of url: URL, sha256: String, stamp: FileStamp) {
        hashCache[url.path] = HashRecord(
            path: stamp.path,
            size: stamp.size,
            mtime: stamp.mtime,
            inode: stamp.inode,
            sha256: sha256.lowercased()
        )
        try? saveHashCache()
    }

    private func fileStamp(_ url: URL) throws -> FileStamp {
        var info = stat()
        guard url.path.withCString({ stat($0, &info) }) == 0 else {
            throw EngineStoreError.checksumMismatch(url.lastPathComponent)
        }
        let mtime = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return FileStamp(
            path: url.path,
            size: String(Int64(info.st_size)),
            mtime: String(mtime),
            inode: String(info.st_ino)
        )
    }

    private func hashCacheURL() throws -> URL {
        let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("Fetch", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("engine-hash-cache.json")
    }

    private func loadHashCache() throws {
        guard !hashCacheLoaded else { return }
        hashCacheLoaded = true
        let url = try hashCacheURL()
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: HashRecord].self, from: data) else { return }
        hashCache = decoded
    }

    private func saveHashCache() throws {
        let data = try JSONEncoder().encode(hashCache)
        try data.write(to: try hashCacheURL(), options: .atomic)
    }

    private func verifyPublishedSum(_ actual: String, channel: String) async throws {
        let sums = channel == "nightly"
            ? "https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/latest/download/SHA2-256SUMS"
            : "https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS"
        guard let url = URL(string: sums) else { throw EngineStoreError.updateFailed("Bad checksum URL") }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 1_000_000 else {
            throw EngineStoreError.updateFailed("Couldn't download the published checksums.")
        }
        guard let text = String(data: data, encoding: .utf8), let expected = Checksum.parseSums(text)["yt-dlp_macos"] else {
            throw EngineStoreError.updateFailed("The published checksum list has no macOS build.")
        }
        guard actual.lowercased() == expected else {
            throw EngineStoreError.updateFailed("The updated engine didn't match its published checksum.")
        }
    }

    private func readVersion(_ binary: URL) async throws -> String {
        let runner = ManagedProcess()
        let lines = VersionLines()
        let code = try await runner.run(
            executable: binary,
            arguments: ["--ignore-config", "--version"],
            environment: ChildEnvironment.make(binDirectory: binary.deletingLastPathComponent()),
            currentDirectory: binary.deletingLastPathComponent(),
            onLine: { _, line in lines.add(line) }
        )
        let version = lines.firstNonEmpty()
        guard code == 0, !version.isEmpty else {
            throw EngineStoreError.updateFailed("Couldn't read the engine version.")
        }
        return version
    }

    private func restore(_ backup: URL, over destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: backup, to: destination)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        removeQuarantine(destination)
    }

    // MARK: - Paths

    private func bundledManifest() -> EngineManifest? {
        guard let url = Bundle.main.url(forResource: "engine-manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(EngineManifest.self, from: data)
    }

    private func bundledBinRoot() -> URL? {
        Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)
    }

    private func supportBinDirectory() throws -> URL {
        let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("Fetch/bin", isDirectory: true)
    }

    private func currentArch() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private func sidecarURL(_ name: String) throws -> URL {
        try supportBinDirectory().appendingPathComponent(name)
    }

    private func readSidecar(named name: String) -> String? {
        guard let url = try? sidecarURL(name), let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func writeSidecar(_ value: String, named name: String) throws {
        let url = try sidecarURL(name)
        try value.write(to: url, atomically: true, encoding: .utf8)
    }

    private func removeQuarantine(_ url: URL) {
        url.path.withCString { path in
            removexattr(path, "com.apple.quarantine", 0)
        }
    }

    private func checkedPhrase(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Up to date · checked today" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "Up to date · checked \(formatter.string(from: date))"
    }
}

private struct HashRecord: Codable, Equatable {
    var path: String
    var size: String
    var mtime: String
    var inode: String
    var sha256: String
}

private struct FileStamp: Equatable {
    var path: String
    var size: String
    var mtime: String
    var inode: String
}

private final class VersionLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func firstNonEmpty() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
    }
}
