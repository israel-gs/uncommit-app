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
}
