import Darwin
import Foundation

enum ProcessStream: Sendable {
    case standardOutput
    case standardError
}

/// Runs a child process with an argument array. There is no shell.
final class ManagedProcess: @unchecked Sendable {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stateLock = NSLock()
    private var didResume = false
    private var didStop = false

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?,
        onLine: @escaping @Sendable (ProcessStream, String) -> Void
    ) async throws -> Int32 {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        process.qualityOfService = .utility

        let outHandle = stdoutPipe.fileHandleForReading
        let errHandle = stderrPipe.fileHandleForReading

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    Self.pump(outHandle, stream: .standardOutput, onLine: onLine)
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    Self.pump(errHandle, stream: .standardError, onLine: onLine)
                    group.leave()
                }
                self.process.terminationHandler = { proc in
                    group.notify(queue: .global(qos: .utility)) {
                        self.finish(.success(proc.terminationStatus), continuation)
                    }
                }
                do {
                    try self.process.run()
                    try? self.stdoutPipe.fileHandleForWriting.close()
                    try? self.stderrPipe.fileHandleForWriting.close()
                } catch {
                    try? outHandle.close()
                    try? errHandle.close()
                    self.finish(.failure(error), continuation)
                }
            }
        }, onCancel: {
            self.stop()
        })
    }

    func stop() {
        stateLock.lock()
        let already = didStop
        didStop = true
        stateLock.unlock()
        guard !already else { return }
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        kill(pid, SIGINT)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.process.isRunning else { return }
            ProcessTree.terminate(pid)
        }
    }

    private func finish(_ result: Result<Int32, Error>, _ continuation: CheckedContinuation<Int32, Error>) {
        stateLock.lock()
        if didResume {
            stateLock.unlock()
            return
        }
        didResume = true
        stateLock.unlock()
        continuation.resume(with: result)
    }

    private static func pump(_ handle: FileHandle, stream: ProcessStream, onLine: @Sendable (ProcessStream, String) -> Void) {
        var buffer = Data()
        while true {
            let chunk: Data
            do {
                guard let read = try handle.read(upToCount: 64 * 1024), !read.isEmpty else { break }
                chunk = read
            } catch {
                break
            }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                var line = buffer.subdata(in: buffer.startIndex..<newline)
                if line.last == 0x0D { line.removeLast() }
                buffer.removeSubrange(buffer.startIndex...newline)
                if let text = String(data: line, encoding: .utf8) {
                    onLine(stream, text)
                }
            }
            if buffer.count > 1_000_000 {
                buffer.removeAll(keepingCapacity: false)
            }
        }
        if !buffer.isEmpty, let text = String(data: buffer, encoding: .utf8), !text.isEmpty {
            onLine(stream, text)
        }
    }
}

enum ProcessTree {
    static func terminate(_ pid: pid_t) {
        for child in childPIDs(of: pid) {
            terminate(child)
        }
        kill(pid, SIGKILL)
    }

    private static func childPIDs(of pid: pid_t) -> [pid_t] {
        let capacity = 256
        var buffer = [pid_t](repeating: 0, count: capacity)
        let returned = buffer.withUnsafeMutableBytes { raw in
            Int(proc_listchildpids(pid, raw.baseAddress, Int32(raw.count)))
        }
        // libproc has shipped both a pid count and a byte count. The buffer is
        // zeroed, and pid 0 is never a child worth signalling (kill(0) hits the
        // process group), so either reading is safe after this filter.
        guard returned > 0 else { return [] }
        let count = returned <= capacity ? returned : returned / MemoryLayout<pid_t>.size
        return buffer.prefix(min(count, capacity)).filter { $0 > 1 }
    }
}

@_silgen_name("proc_listchildpids")
private func proc_listchildpids(_ ppid: Int32, _ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32

enum ChildEnvironment {
    static func make(binDirectory: URL) -> [String: String] {
        [
            "PATH": binDirectory.path,
            "HOME": NSHomeDirectory(),
            "TMPDIR": NSTemporaryDirectory(),
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "USER": NSUserName(),
        ]
    }
}

enum DNSLookup {
    /// Numeric addresses for a host. Empty when resolution fails; callers then let the downloader try.
    static func addresses(for host: String) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                var info: UnsafeMutablePointer<addrinfo>?
                let code = getaddrinfo(host, nil, &hints, &info)
                guard code == 0, let info else {
                    continuation.resume(returning: [])
                    return
                }
                defer { freeaddrinfo(info) }
                var results: [String] = []
                var pointer: UnsafeMutablePointer<addrinfo>? = info
                while let current = pointer {
                    if let address = current.pointee.ai_addr {
                        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(address, current.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                            results.append(String(cString: buffer))
                        }
                    }
                    pointer = current.pointee.ai_next
                }
                continuation.resume(returning: results)
            }
        }
    }
}
