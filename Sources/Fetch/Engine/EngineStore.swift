import Darwin
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
}

actor EngineStore {
    static let shared = EngineStore()

    private var cached: EngineBinaries?
    private var versions = EngineVersions(ytDlp: "—", deno: "—", ffmpeg: "—", checkedAt: nil, upToDate: false, status: "Not checked yet")
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
        do {
            _ = try await update(channel: "stable")
        } catch {
            versions.status = "Couldn't check for an update"
        }
    }

    @discardableResult
    func update(channel: String) async throws -> String {
        let binaries = try await prepare()
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
        guard code == 0 else {
            try? restore(backup, over: binaries.ytDlp)
            throw EngineStoreError.updateFailed("The engine update didn't finish (exit \(code)).")
        }
        do {
            try await verifyPublishedSum(of: binaries.ytDlp, channel: channel)
        } catch {
            try? restore(backup, over: binaries.ytDlp)
            cached = nil
            throw error
        }
        try? fileManager.removeItem(at: backup)
        removeQuarantine(binaries.ytDlp)
        let version = try await readVersion(binaries.ytDlp)
        try writeSidecar(version, named: "yt-dlp.version")
        let digest = try Checksum.sha256Hex(of: binaries.ytDlp)
        try writeSidecar(digest, named: "yt-dlp.sha256")
        cached = binaries
        let now = Date()
        UserDefaults.standard.set(now, forKey: "lastEngineCheck")
        versions.ytDlp = version
        versions.checkedAt = now
        versions.upToDate = true
        versions.status = checkedPhrase(now)
        return version
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
            expected: manifest.binaries["yt-dlp"]?["universal"],
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
        let sourceHash = try Checksum.sha256Hex(of: source)
        guard sourceHash == expected.lowercased() else { throw EngineStoreError.checksumMismatch(name) }
        if fileManager.fileExists(atPath: destination.path) {
            let current = try? Checksum.sha256Hex(of: destination)
            if current == expected.lowercased() {
                removeQuarantine(destination)
                return
            }
            try? fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
        let copied = try Checksum.sha256Hex(of: destination)
        guard copied == expected.lowercased() else {
            try? fileManager.removeItem(at: destination)
            throw EngineStoreError.checksumMismatch(name)
        }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        removeQuarantine(destination)
        try writeSidecar(copied, named: "\(name).sha256")
    }

    private func installYTDLP(source: URL, destination: URL, expected: String?, bundledVersion: String, forceBundle: Bool) throws {
        guard let expected else { throw EngineStoreError.checksumMismatch("yt-dlp") }
        let sourceHash = try Checksum.sha256Hex(of: source)
        guard sourceHash == expected.lowercased() else { throw EngineStoreError.checksumMismatch("yt-dlp") }

        if !forceBundle, fileManager.fileExists(atPath: destination.path),
           let sidecar = readSidecar(named: "yt-dlp.sha256") {
            let current = try Checksum.sha256Hex(of: destination)
            if current == sidecar.lowercased() {
                removeQuarantine(destination)
                return
            }
        }

        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
        let copied = try Checksum.sha256Hex(of: destination)
        guard copied == expected.lowercased() else {
            try? fileManager.removeItem(at: destination)
            throw EngineStoreError.checksumMismatch("yt-dlp")
        }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        removeQuarantine(destination)
        try writeSidecar(copied, named: "yt-dlp.sha256")
        try writeSidecar(bundledVersion, named: "yt-dlp.version")
    }

    private func verifyPublishedSum(of binary: URL, channel: String) async throws {
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
        let actual = try Checksum.sha256Hex(of: binary)
        guard actual == expected else {
            throw EngineStoreError.updateFailed("The updated engine didn't match its published checksum.")
        }
    }

    private func readVersion(_ binary: URL) async throws -> String {
        let runner = ManagedProcess()
        var lines: [String] = []
        let code = try await runner.run(
            executable: binary,
            arguments: ["--ignore-config", "--version"],
            environment: ChildEnvironment.make(binDirectory: binary.deletingLastPathComponent()),
            currentDirectory: binary.deletingLastPathComponent(),
            onLine: { _, line in lines.append(line) }
        )
        let version = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
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
