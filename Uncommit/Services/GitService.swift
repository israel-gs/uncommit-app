import Foundation

enum GitService {

    static func currentBranch(at repoPath: String) async throws -> String {
        let result = try await ShellExecutor.run(
            "git", arguments: ["branch", "--show-current"],
            workingDirectory: repoPath
        )
        return result.isEmpty ? "HEAD (detached)" : result
    }

    static func localStatus(at repoPath: String) async throws -> (staged: [String], modified: [String], untracked: [String], conflicts: [String]) {
        let output = try await ShellExecutor.run(
            "git", arguments: ["status", "--porcelain=v1"],
            workingDirectory: repoPath
        )

        guard !output.isEmpty else {
            return ([], [], [], [])
        }

        var staged: [String] = []
        var modified: [String] = []
        var untracked: [String] = []
        var conflicts: [String] = []

        for line in output.components(separatedBy: "\n") where line.count >= 3 {
            let chars = Array(line)
            let x = chars[0]
            let y = chars[1]
            // File name starts at index 3 (after "XY ")
            let fileName = String(line.dropFirst(3))
            // For renames "old -> new", show just the new name
            let displayName: String
            if let arrowRange = fileName.range(of: " -> ") {
                displayName = String(fileName[arrowRange.upperBound...])
            } else {
                displayName = fileName
            }

            if (x == "U" || y == "U") || (x == "A" && y == "A") || (x == "D" && y == "D") {
                conflicts.append(displayName)
            } else if x == "?" && y == "?" {
                untracked.append(displayName)
            } else {
                if x != " " && x != "?" { staged.append(displayName) }
                if y != " " && y != "?" { modified.append(displayName) }
            }
        }

        return (staged, modified, untracked, conflicts)
    }

    static func aheadBehind(at repoPath: String) async throws -> (ahead: Int, behind: Int, hasTracking: Bool) {
        do {
            _ = try await ShellExecutor.run(
                "git", arguments: ["rev-parse", "--abbrev-ref", "@{u}"],
                workingDirectory: repoPath
            )
        } catch {
            return (0, 0, false)
        }

        let aheadStr = try await ShellExecutor.run(
            "git", arguments: ["rev-list", "--count", "@{u}..HEAD"],
            workingDirectory: repoPath
        )
        let behindStr = try await ShellExecutor.run(
            "git", arguments: ["rev-list", "--count", "HEAD..@{u}"],
            workingDirectory: repoPath
        )

        return (Int(aheadStr) ?? 0, Int(behindStr) ?? 0, true)
    }

    static func fetch(at repoPath: String) async throws {
        _ = try await ShellExecutor.run(
            "git", arguments: ["fetch", "--all", "--prune"],
            workingDirectory: repoPath,
            timeout: 30
        )
    }

    /// Runs all status checks sequentially. Returns Result to never throw.
    static func fullStatus(at repoPath: String) async -> Result<GitRepoStatus, Error> {
        do {
            let branch = try await currentBranch(at: repoPath)
            let (staged, modified, untracked, conflicts) = try await localStatus(at: repoPath)
            let (ahead, behind, hasTracking) = try await aheadBehind(at: repoPath)

            let status = GitRepoStatus(
                branchName: branch,
                stagedFiles: staged,
                modifiedFiles: modified,
                untrackedFiles: untracked,
                conflictFiles: conflicts,
                aheadCount: ahead,
                behindCount: behind,
                hasRemoteTrackingBranch: hasTracking
            )
            return .success(status)
        } catch {
            return .failure(error)
        }
    }
}
