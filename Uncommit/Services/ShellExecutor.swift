import Foundation
import os

private let logger = Logger(subsystem: "com.uncommit.app", category: "ShellExecutor")

enum ShellError: Error, LocalizedError {
    case processError(exitCode: Int32, stderr: String)
    case timeout
    case invalidWorkingDirectory(String)
    case pipeUnavailable(Int32)

    var errorDescription: String? {
        switch self {
        case .processError(let code, let stderr):
            return "Exit code \(code): \(stderr)"
        case .timeout:
            return "Process timed out"
        case .invalidWorkingDirectory(let path):
            return "Invalid directory: \(path)"
        case .pipeUnavailable(let code):
            return "Could not open a pipe for git (errno \(code))"
        }
    }
}

/// Thread-safe one-shot flag. Set by the timeout watchdog and read by the
/// termination handler, which run on different queues.
private final class FlagBox: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)

    func set() { lock.withLock { $0 = true } }
    var isSet: Bool { lock.withLock { $0 } }
}

/// Thread-safe one-shot continuation wrapper.
private final class ContinuationBox: Sendable {
    private let lock: OSAllocatedUnfairLock<CheckedContinuation<String, Error>?>

    init(_ cont: CheckedContinuation<String, Error>) {
        self.lock = OSAllocatedUnfairLock(initialState: cont)
    }

    func resume(returning value: String) {
        let cont = lock.withLock { state -> CheckedContinuation<String, Error>? in
            let captured = state
            state = nil
            return captured
        }
        cont?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        let cont = lock.withLock { state -> CheckedContinuation<String, Error>? in
            let captured = state
            state = nil
            return captured
        }
        cont?.resume(throwing: error)
    }
}

/// Collects one end of a pipe without ever blocking a thread, and owns that
/// descriptor: it is closed exactly once, by the source's cancel handler.
///
/// This used to be `Pipe` + `readabilityHandler`, finished off with
/// `readDataToEndOfFile()` from inside the termination handler. That call waits
/// for *every* holder of the write end to let go, and the process we launch is
/// not always the last one — `git` passes its stdout straight to whatever it
/// spawns (background auto-gc, `ssh`, a credential helper), and those outlive
/// it. Each of those reads sat there holding two descriptors, and once enough
/// had piled up the app hit its descriptor limit: from that moment `Pipe()`
/// hands back garbage and every git call dies with "Bad file descriptor", on
/// every repository at once, until the app is relaunched.
///
/// Reading non-blocking off the descriptor we own sidesteps all of it. By the
/// time the child is reaped everything it wrote is already in the pipe buffer,
/// so a drain that stops at `EAGAIN` loses nothing and waits for no one.
private final class PipeDrain: Sendable {
    private let fd: Int32
    private let queue: DispatchQueue
    private let source: DispatchSourceRead
    private let buffer = OSAllocatedUnfairLock<Data>(initialState: Data())
    private let hasFinished = OSAllocatedUnfairLock(initialState: false)

    init(readingFrom fd: Int32, on queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
        // Non-blocking, so a drain that finds the pipe empty returns instead of
        // parking the queue until somebody writes or closes.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let buffer = self.buffer
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { PipeDrain.drain(fd, into: buffer) }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    /// Collects whatever is left and releases the descriptor. Idempotent, and
    /// safe from any thread except the drain queue itself: the final read runs
    /// on that queue so it can't interleave with the event handler.
    func finish() {
        let alreadyFinished = hasFinished.withLock { finished -> Bool in
            defer { finished = true }
            return finished
        }
        guard !alreadyFinished else { return }

        let fd = self.fd
        let buffer = self.buffer
        queue.sync { PipeDrain.drain(fd, into: buffer) }
        source.cancel()
    }

    func text() -> String {
        buffer.withLock { data in
            String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    /// Reads until the pipe is empty or closed. Never waits for more.
    private static func drain(_ fd: Int32, into buffer: OSAllocatedUnfairLock<Data>) {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress, raw.count)
            }
            if count > 0 {
                let piece = Data(chunk[0..<count])
                buffer.withLock { $0.append(piece) }
            } else if count == 0 {
                return                          // EOF
            } else if errno == EINTR {
                continue                        // interrupted, try again
            } else {
                return                          // EAGAIN: nothing more for now
            }
        }
    }
}

enum ShellExecutor {

    /// How long a process that ignores SIGTERM gets before SIGKILL.
    private static let sigkillGrace: TimeInterval = 2
    /// How long after SIGKILL we stop waiting for a termination handler that
    /// may never arrive, and answer the caller ourselves.
    private static let abandonGrace: TimeInterval = 5

    /// Resolved absolute path for `git`, looked up once at first use across
    /// the standard install locations. Skipping the `/usr/bin/env` exec for
    /// every git call shaves overhead off the polling loop.
    private static let resolvedGitPath: String? = {
        let candidates = [
            "/usr/bin/git",                  // Xcode Command Line Tools
            "/opt/homebrew/bin/git",         // Apple Silicon Homebrew
            "/usr/local/bin/git"             // Intel Homebrew
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }()

    /// Runs a command asynchronously WITHOUT blocking any Swift concurrency threads.
    /// Uses Process.terminationHandler + a non-blocking drain so nothing ever calls
    /// waitUntilExit(), and no read waits on a process we didn't launch.
    static func run(
        _ command: String,
        arguments: [String] = [],
        workingDirectory: String,
        timeout: TimeInterval = 10
    ) async throws -> String {
        let startTime = CFAbsoluteTimeGetCurrent()
        let shortDir = URL(fileURLWithPath: workingDirectory).lastPathComponent
        let argsSummary = arguments.joined(separator: " ")
        logger.debug("▶ \(command) \(argsSummary) [dir: \(shortDir)]")

        guard FileManager.default.fileExists(atPath: workingDirectory) else {
            logger.error("✗ Invalid directory: \(workingDirectory)")
            throw ShellError.invalidWorkingDirectory(workingDirectory)
        }

        // Fast path: skip `/usr/bin/env` for known commands with cached
        // absolute paths.
        let executablePath: String
        let processArgs: [String]
        if command == "git", let gitPath = resolvedGitPath {
            executablePath = gitPath
            processArgs = arguments
        } else {
            executablePath = "/usr/bin/env"
            processArgs = [command] + arguments
        }

        return try await withCheckedThrowingContinuation { continuation in
            let box = ContinuationBox(continuation)
            // Set before we signal the process, so the termination handler can
            // tell "we killed it" from "it failed on its own".
            let timedOut = FlagBox()

            // Our own descriptors rather than `Pipe()`: closing them is the
            // whole point, and `Pipe` only closes on deallocation.
            var stdoutFDs: [Int32] = [-1, -1]
            var stderrFDs: [Int32] = [-1, -1]
            guard pipe(&stdoutFDs) == 0 else {
                logger.error("✗ pipe() failed for \(command): errno \(errno)")
                box.resume(throwing: ShellError.pipeUnavailable(errno))
                return
            }
            guard pipe(&stderrFDs) == 0 else {
                logger.error("✗ pipe() failed for \(command): errno \(errno)")
                close(stdoutFDs[0])
                close(stdoutFDs[1])
                box.resume(throwing: ShellError.pipeUnavailable(errno))
                return
            }

            let ioQueue = DispatchQueue(label: "com.uncommit.app.shell-io")
            let stdoutDrain = PipeDrain(readingFrom: stdoutFDs[0], on: ioQueue)
            let stderrDrain = PipeDrain(readingFrom: stderrFDs[0], on: ioQueue)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = processArgs
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
            // closeOnDealloc: false — Process leaves a plain FileHandle's
            // descriptor alone, so we close our copy below, once the child has
            // its own.
            process.standardOutput = FileHandle(fileDescriptor: stdoutFDs[1], closeOnDealloc: false)
            process.standardError = FileHandle(fileDescriptor: stderrFDs[1], closeOnDealloc: false)

            var env = ProcessInfo.processInfo.environment
            let additionalPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin"
            env["PATH"] = additionalPaths + ":" + (env["PATH"] ?? "")
            env["GIT_TERMINAL_PROMPT"] = "0"
            env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
            process.environment = env

            // When the process exits, take what it wrote, release the
            // descriptors, and answer the caller.
            process.terminationHandler = { proc in
                stdoutDrain.finish()
                stderrDrain.finish()

                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                if proc.terminationStatus == 0 {
                    logger.debug("✓ \(command) \(argsSummary) done [\(String(format: "%.2f", elapsed))s]")
                    box.resume(returning: stdoutDrain.text())
                } else if timedOut.isSet {
                    // We SIGTERM'd it, so terminationStatus is just our signal.
                    // Reporting "Exit code 15:" here told the user nothing.
                    logger.warning("⏱ \(command) \(argsSummary) timed out after \(timeout)s")
                    box.resume(throwing: ShellError.timeout)
                } else {
                    let stderr = stderrDrain.text()
                    logger.warning("✗ \(command) \(argsSummary) exit=\(proc.terminationStatus) [\(String(format: "%.2f", elapsed))s] stderr: \(stderr)")
                    box.resume(throwing: ShellError.processError(
                        exitCode: proc.terminationStatus,
                        stderr: stderr
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                logger.error("✗ Failed to launch \(command): \(error.localizedDescription)")
                close(stdoutFDs[1])
                close(stderrFDs[1])
                stdoutDrain.finish()
                stderrDrain.finish()
                box.resume(throwing: error)
                return
            }

            // The child holds its own copies now. Ours have to go, or the
            // drains would never see the end of the output.
            close(stdoutFDs[1])
            close(stderrFDs[1])

            // Timeout: kill the process if it's still running.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [process] in
                guard process.isRunning else { return }
                logger.warning("⏱ Timeout (\(timeout)s) — sending SIGTERM to \(command) \(argsSummary)")
                timedOut.set()
                process.terminate()

                // If still alive (git ignoring SIGTERM), force kill
                DispatchQueue.global().asyncAfter(deadline: .now() + sigkillGrace) {
                    if process.isRunning {
                        logger.warning("⏱ SIGTERM ignored — sending SIGKILL to \(command) \(argsSummary)")
                        kill(process.processIdentifier, SIGKILL)
                    }
                }

                // Last resort: a termination handler that never arrives would
                // otherwise leave the caller suspended forever, holding its
                // descriptors with it. Both the box and the drains are
                // one-shot, so this does nothing once the process is reaped
                // normally.
                DispatchQueue.global().asyncAfter(deadline: .now() + abandonGrace) {
                    guard !process.isRunning else { return }
                    stdoutDrain.finish()
                    stderrDrain.finish()
                    box.resume(throwing: ShellError.timeout)
                }
            }
        }
    }
}
