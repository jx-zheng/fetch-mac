import Darwin
import Foundation

enum ProcessStream: Sendable {
    case standardOutput
    case standardError
}

struct ProcessLaunchError: Error, CustomStringConvertible {
    var description: String
}

/// Runs a child in its own process group, with an argument array. There is no shell.
/// Cancel signals the whole group, including ffmpeg started by yt-dlp.
final class ManagedProcess: @unchecked Sendable {
    private let stateLock = NSLock()
    private var didResume = false
    private var didStop = false
    private var pgid: pid_t = 0

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?,
        onLine: @escaping @Sendable (ProcessStream, String) -> Void
    ) async throws -> Int32 {
        stateLock.lock()
        let alreadyStopped = didStop
        stateLock.unlock()
        if alreadyStopped { throw CancellationError() }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let outRead = stdoutPipe.fileHandleForReading
        let errRead = stderrPipe.fileHandleForReading
        let outWrite = stdoutPipe.fileHandleForWriting
        let errWrite = stderrPipe.fileHandleForWriting

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        let pid = try self.spawn(
                            executable: executable,
                            arguments: arguments,
                            environment: environment,
                            currentDirectory: currentDirectory,
                            stdout: outWrite.fileDescriptor,
                            stderr: errWrite.fileDescriptor,
                            closeInChild: [outRead.fileDescriptor, errRead.fileDescriptor, outWrite.fileDescriptor, errWrite.fileDescriptor]
                        )
                        try? outWrite.close()
                        try? errWrite.close()
                        self.stateLock.lock()
                        self.pgid = pid
                        let stopNow = self.didStop
                        self.stateLock.unlock()
                        if stopNow {
                            self.signalGroup(pid)
                        }
                        let group = DispatchGroup()
                        group.enter()
                        DispatchQueue.global(qos: .utility).async {
                            Self.pump(outRead, stream: .standardOutput, onLine: onLine)
                            group.leave()
                        }
                        group.enter()
                        DispatchQueue.global(qos: .utility).async {
                            Self.pump(errRead, stream: .standardError, onLine: onLine)
                            group.leave()
                        }
                        var status: Int32 = 0
                        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                        group.wait()
                        let code = Self.exitCode(status)
                        self.finish(.success(code), continuation)
                    } catch {
                        try? outRead.close()
                        try? errRead.close()
                        try? outWrite.close()
                        try? errWrite.close()
                        self.finish(.failure(error), continuation)
                    }
                }
            }
        }, onCancel: {
            self.stop()
        })
    }

    /// Safe to call before `run`. A cancel that wins the race never starts the child.
    func stop() {
        stateLock.lock()
        let already = didStop
        didStop = true
        let group = pgid
        stateLock.unlock()
        guard !already else { return }
        guard group > 1 else { return }
        signalGroup(group)
    }

    private func signalGroup(_ group: pid_t) {
        guard group > 1 else { return }
        kill(-group, SIGINT)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
            kill(-group, SIGKILL)
        }
    }

    private func spawn(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?,
        stdout: Int32,
        stderr: Int32,
        closeInChild: [Int32]
    ) throws -> pid_t {
        stateLock.lock()
        let stopped = didStop
        stateLock.unlock()
        if stopped { throw CancellationError() }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw ProcessLaunchError(description: "Couldn't prepare the engine process.")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else {
            throw ProcessLaunchError(description: "Couldn't prepare the engine process.")
        }
        defer { posix_spawnattr_destroy(&attr) }

        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF)
        posix_spawnattr_setflags(&attr, flags)
        var group: pid_t = 0
        posix_spawnattr_setpgroup(&attr, group)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGINT)
        sigaddset(&defaults, SIGTERM)
        posix_spawnattr_setsigdefault(&attr, &defaults)

        let devnull = open("/dev/null", O_RDONLY)
        if devnull < 0 {
            throw ProcessLaunchError(description: "Couldn't open a standard input for the engine.")
        }
        defer { close(devnull) }
        posix_spawn_file_actions_adddup2(&actions, stdout, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderr, STDERR_FILENO)
        posix_spawn_file_actions_adddup2(&actions, devnull, STDIN_FILENO)
        posix_spawn_file_actions_addclose(&actions, devnull)
        for fd in closeInChild where fd > STDERR_FILENO {
            posix_spawn_file_actions_addclose(&actions, fd)
        }
        let directory: UnsafeMutablePointer<CChar>? = currentDirectory.flatMap { strdup($0.path) }
        defer { free(directory) }
        if let directory, posix_spawn_file_actions_addchdir_np(&actions, directory) != 0 {
            throw ProcessLaunchError(description: "Couldn't set the engine working directory.")
        }

        var argvCopies = ([executable.path] + arguments).map { strdup($0) }
        defer { argvCopies.forEach { free($0) } }
        var argv: [UnsafeMutablePointer<CChar>?] = argvCopies
        argv.append(nil)
        var envCopies = environment.map { strdup("\($0.key)=\($0.value)") }
        defer { envCopies.forEach { free($0) } }
        var envp: [UnsafeMutablePointer<CChar>?] = envCopies
        envp.append(nil)

        var pid: pid_t = 0
        let rc: Int32 = try executable.path.withCString { path in
            try argv.withUnsafeMutableBufferPointer { argvBuf in
                try envp.withUnsafeMutableBufferPointer { envBuf in
                    guard let argvPtr = argvBuf.baseAddress, let envPtr = envBuf.baseAddress else {
                        throw ProcessLaunchError(description: "Couldn't start the engine.")
                    }
                    return posix_spawn(&pid, path, &actions, &attr, argvPtr, envPtr)
                }
            }
        }
        if rc != 0 {
            throw ProcessLaunchError(description: "Couldn't start the engine (\(String(cString: strerror(rc)))).")
        }
        stateLock.lock()
        let stopNow = didStop
        stateLock.unlock()
        if stopNow {
            kill(-pid, SIGINT)
            kill(-pid, SIGKILL)
        }
        return pid
    }

    private static func exitCode(_ status: Int32) -> Int32 {
        if status & 0x7f == 0 { return (status >> 8) & 0xff }
        return status & 0x7f
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
