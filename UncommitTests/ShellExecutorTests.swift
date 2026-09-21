import XCTest
@testable import Uncommit

final class ShellExecutorTests: XCTestCase {

    /// A command that outlives its timeout must surface as `.timeout`. It used
    /// to come back as `.processError(exitCode: 15)` — our own SIGTERM — and the
    /// repo row showed the user a bare "Exit code 15:".
    func testTimeoutSurfacesAsTimeoutError() async {
        do {
            _ = try await ShellExecutor.run(
                "sleep", arguments: ["5"],
                workingDirectory: NSTemporaryDirectory(),
                timeout: 0.5
            )
            XCTFail("Expected the command to time out")
        } catch let error as ShellError {
            guard case .timeout = error else {
                return XCTFail("Expected .timeout, got \(error)")
            }
        } catch {
            XCTFail("Expected ShellError.timeout, got \(error)")
        }
    }

    /// The timeout path must not swallow real failures: a command that exits
    /// non-zero on its own still reports its exit code and stderr.
    func testNonZeroExitStillReportsProcessError() async {
        do {
            _ = try await ShellExecutor.run(
                "git", arguments: ["rev-parse", "--verify", "HEAD"],
                workingDirectory: NSTemporaryDirectory(),
                timeout: 10
            )
            XCTFail("Expected a non-zero exit outside a git repository")
        } catch let error as ShellError {
            guard case .processError = error else {
                return XCTFail("Expected .processError, got \(error)")
            }
        } catch {
            XCTFail("Expected ShellError.processError, got \(error)")
        }
    }

    func testInvalidWorkingDirectoryThrowsBeforeLaunching() async {
        do {
            _ = try await ShellExecutor.run(
                "git", arguments: ["status"],
                workingDirectory: "/nope/definitely/not/here"
            )
            XCTFail("Expected an invalid-directory error")
        } catch let error as ShellError {
            guard case .invalidWorkingDirectory = error else {
                return XCTFail("Expected .invalidWorkingDirectory, got \(error)")
            }
        } catch {
            XCTFail("Expected ShellError.invalidWorkingDirectory, got \(error)")
        }
    }

    /// The regression that took the whole app down: `git` hands its stdout to
    /// whatever it spawns, and those children outlive it. The old executor
    /// finished each run with `readDataToEndOfFile()`, which waits for the last
    /// holder of the write end — so every such call parked a thread and sat on
    /// two descriptors until that stranger exited. After enough of them the app
    /// hit its descriptor limit, `Pipe()` started handing back garbage, and
    /// every repository showed "Bad file descriptor" at once.
    ///
    /// Three things have to hold: the call returns as soon as OUR process
    /// exits, the descriptors come back, and the output is still complete.
    func testSurvivingGrandchildDoesNotStrandDescriptors() async throws {
        let before = openDescriptorCount()
        let started = Date()

        for index in 0..<20 {
            let output = try await ShellExecutor.run(
                "sh",
                arguments: ["-c", "sleep 3 & echo output-\(index); exit 0"],
                workingDirectory: NSTemporaryDirectory(),
                timeout: 10
            )
            XCTAssertEqual(output, "output-\(index)", "Output was truncated by the early drain")
        }

        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(
            elapsed, 10,
            "Each run waited for the surviving `sleep` instead of for its own child"
        )

        let leaked = openDescriptorCount() - before
        XCTAssertLessThan(
            leaked, 8,
            "\(leaked) descriptors stayed open after 20 runs"
        )
    }

    /// Descriptors must also come back when the command is killed by the
    /// timeout, not just when it exits on its own.
    func testTimedOutCommandReleasesDescriptors() async {
        let before = openDescriptorCount()

        for _ in 0..<10 {
            _ = try? await ShellExecutor.run(
                "sleep", arguments: ["30"],
                workingDirectory: NSTemporaryDirectory(),
                timeout: 0.3
            )
        }

        let leaked = openDescriptorCount() - before
        XCTAssertLessThan(leaked, 8, "\(leaked) descriptors stayed open after 10 timeouts")
    }

    /// Open descriptors held by this process. Capped: the soft limit can be in
    /// the millions, and every repo the app watches only ever uses low numbers.
    private func openDescriptorCount() -> Int {
        var count = 0
        for fd in 0..<Int32(4096) where fcntl(fd, F_GETFD) != -1 { count += 1 }
        return count
    }
}
