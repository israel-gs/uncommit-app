import Foundation
import os

private let logger = Logger(subsystem: "com.uncommit.app", category: "ShellExecutor")

enum ShellError: Error, LocalizedError {
    case processError(exitCode: Int32, stderr: String)
    case timeout
    case invalidWorkingDirectory(String)

    var errorDescription: String? {
        switch self {
        case .processError(let code, let stderr):
            return "Exit code \(code): \(stderr)"
        case .timeout:
            return "Process timed out"
        case .invalidWorkingDirectory(let path):
            return "Invalid directory: \(path)"
        }
    }
}

/// Thread-safe buffer to collect pipe output.
private final class DataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func toString() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// Thread-safe one-shot continuation wrapper.
private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?

    init(_ cont: CheckedContinuation<String, Error>) {
        self.continuation = cont
    }

    func resume(returning value: String) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(throwing: error)
    }
}

enum ShellExecutor {

    /// Runs a command asynchronously WITHOUT blocking any Swift concurrency threads.
    /// Uses Process.terminationHandler + readabilityHandler so nothing ever calls waitUntilExit().
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

        return try await withCheckedThrowingContinuation { continuation in
            let box = ContinuationBox(continuation)
            let stdoutBuffer = DataBuffer()
            let stderrBuffer = DataBuffer()

            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + arguments
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            var env = ProcessInfo.processInfo.environment
            let additionalPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin"
            env["PATH"] = additionalPaths + ":" + (env["PATH"] ?? "")
            env["GIT_TERMINAL_PROMPT"] = "0"
            env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
            process.environment = env

            // Drain pipes asynchronously to avoid buffer-full deadlock
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { stdoutBuffer.append(chunk) }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { stderrBuffer.append(chunk) }
            }

            // When process exits, stop draining, collect final data, resume continuation
            process.terminationHandler = { proc in
                // Stop handlers
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                // Drain any remaining bytes
                let finalOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                if !finalOut.isEmpty { stdoutBuffer.append(finalOut) }
                let finalErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                if !finalErr.isEmpty { stderrBuffer.append(finalErr) }

                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                if proc.terminationStatus == 0 {
                    logger.debug("✓ \(command) \(argsSummary) done [\(String(format: "%.2f", elapsed))s]")
                    box.resume(returning: stdoutBuffer.toString())
                } else {
                    let stderr = stderrBuffer.toString()
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
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                box.resume(throwing: error)
                return
            }

            // Timeout: kill process if it's still running
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [process] in
                if process.isRunning {
                    logger.warning("⏱ Timeout (\(timeout)s) — sending SIGTERM to \(command) \(argsSummary)")
                    process.terminate()
                    // If still alive after 2s (git ignoring SIGTERM), force kill
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        if process.isRunning {
                            logger.warning("⏱ SIGTERM ignored — sending SIGKILL to \(command) \(argsSummary)")
                            kill(process.processIdentifier, SIGKILL)
                        }
                    }
                }
            }
        }
    }
}
