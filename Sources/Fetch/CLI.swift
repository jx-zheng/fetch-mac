import FetchCore
import Foundation

enum CLI {
    static func run() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let commandIndex = arguments.firstIndex(of: "--cli"), arguments.indices.contains(commandIndex + 1) else {
            complain("usage: Fetch --cli version|metadata|download|update …", 2)
        }
        let command = arguments[commandIndex + 1]
        let rest = Array(arguments.dropFirst(commandIndex + 2))
        do {
            switch command {
            case "version":
                let binaries = try await EngineStore.shared.prepare()
                let yt = try await version(of: binaries.ytDlp, arguments: ["--ignore-config", "--version"], directory: binaries.directory)
                let deno = try await version(of: binaries.deno, arguments: ["--version"], directory: binaries.directory)
                let ffmpeg = try await version(of: binaries.ffmpeg, arguments: ["-version"], directory: binaries.directory)
                print("yt-dlp \(yt)")
                print("deno \(deno)")
                print("ffmpeg \(ffmpeg.split(separator: "\n").first ?? "")")
            case "metadata":
                guard let raw = rest.first, case .success(let url) = URLValidator.validate(raw) else {
                    complain("metadata needs one http(s) URL", 2)
                }
                let info = try await DownloadService().fetchInfo(url: url, cookiesFromBrowser: nil)
                let plan = FormatSelector.plan(SelectionInput(
                    extractorKey: info.extractorKey ?? info.extractor,
                    duration: info.duration,
                    formats: info.formats,
                    container: .mp4H264,
                    quality: .best,
                    maxBytes: nil
                ))
                let summary: [String: Any] = [
                    "title": info.title,
                    "site": info.siteName,
                    "duration": info.duration ?? 0,
                    "formats": info.formats.count,
                    "selector": plan?.selector ?? "",
                    "noWatermark": plan?.noWatermark ?? false,
                ]
                print(try json(summary))
            case "download":
                try await download(rest)
            case "update":
                let channel = rest.first ?? "stable"
                guard channel == "stable" || channel == "nightly" else {
                    complain("update channel must be stable or nightly", 2)
                }
                let version = try await EngineStore.shared.update(channel: channel)
                print("yt-dlp \(version)")
                print("UPDATE_OK")
            default:
                complain("unknown command \(command)", 2)
            }
        } catch let failure as EngineFailure {
            let code: Int32 = (failure.mapped.kind == .network || failure.mapped.kind == .region) ? 4 : 3
            complain("\(failure.mapped.kind) \(failure.mapped.detail)", code)
        } catch {
            complain("\(error)", 3)
        }
    }

    private static func complain(_ message: String, _ code: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(code)
    }

    private static func download(_ arguments: [String]) async throws {
        var rawURL: String?
        var output = FileManager.default.temporaryDirectory
        var maxMB: Double?
        var format = ContainerFormat.mp4H264
        var quality = Quality.best
        var limitRate: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--output":
                index += 1
                output = URL(fileURLWithPath: arguments[index], isDirectory: true)
            case "--max-mb":
                index += 1
                maxMB = Double(arguments[index])
            case "--format":
                index += 1
                format = ContainerFormat(rawValue: arguments[index]) ?? .mp4H264
            case "--quality":
                index += 1
                quality = Quality(rawValue: arguments[index]) ?? .best
            case "--limit-rate":
                index += 1
                guard arguments.indices.contains(index), Self.isSafeRate(arguments[index]) else {
                    complain("limit-rate must be digits with an optional K or M", 2)
                }
                limitRate = arguments[index]
            default:
                if rawURL == nil { rawURL = argument }
            }
            index += 1
        }
        guard let rawURL, case .success(let url) = URLValidator.validate(rawURL) else {
            complain("download needs one http(s) URL", 2)
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let service = DownloadService()
        service.limitRate = limitRate
        let interrupt = installInterrupt(service)
        defer { interrupt.cancel() }
        let info = try await service.fetchInfo(url: url, cookiesFromBrowser: nil)
        let cap = maxMB.map { Int($0 * 1_000_000) }
        let outcome = try await service.download(
            url: url,
            info: info,
            container: format,
            quality: quality,
            maxBytes: cap,
            outputDirectory: output,
            cookiesFromBrowser: nil,
            onProgress: { _ in }
        )
        let summary: [String: Any] = [
            "path": outcome.fileURL.path,
            "bytes": outcome.byteCount,
            "transcoded": outcome.transcoded,
            "hardware": outcome.hardware,
            "noWatermark": outcome.noWatermark,
            "audio": outcome.hasAudio,
            "video": outcome.hasVideo,
            "width": outcome.width ?? 0,
            "height": outcome.height ?? 0,
            "underCap": outcome.underCap,
        ]
        print("FETCH_RESULT \(try json(summary))")
    }

    private static func isSafeRate(_ value: String) -> Bool {
        guard (1...8).contains(value.count), let last = value.last else { return false }
        let digits = last.isNumber ? value : String(value.dropLast())
        let suffixOK = last.isNumber || last == "K" || last == "M" || last == "k" || last == "m"
        return suffixOK && !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    private static func installInterrupt(_ service: DownloadService) -> DispatchSourceSignal {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { service.cancel() }
        source.resume()
        return source
    }

    private static func version(of executable: URL, arguments: [String], directory: URL) async throws -> String {
        let runner = ManagedProcess()
        let lines = LineBox()
        _ = try await runner.run(
            executable: executable,
            arguments: arguments,
            environment: ChildEnvironment.make(binDirectory: directory),
            currentDirectory: directory,
            onLine: { _, line in lines.add(line) }
        )
        return lines.firstNonEmpty()
    }

    private static func json(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

private final class LineBox: @unchecked Sendable {
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
        return lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
    }
}
