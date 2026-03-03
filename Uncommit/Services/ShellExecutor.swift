import Foundation

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
        guard FileManager.default.fileExists(atPath: workingDirectory) else {
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

                if proc.terminationStatus == 0 {
                    box.resume(returning: stdoutBuffer.toString())
                } else {
                    box.resume(throwing: ShellError.processError(
                        exitCode: proc.terminationStatus,
                        stderr: stderrBuffer.toString()
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                box.resume(throwing: error)
                return
            }

            // Timeout: kill process if it's still running
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [process] in
                if process.isRunning {
                    process.terminate()
                    // terminationHandler will fire and resume the continuation
                }
            }
        }
    }
}
