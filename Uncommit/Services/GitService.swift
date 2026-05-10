import Foundation
import os

private let logger = Logger(subsystem: "com.uncommit.app", category: "GitService")

enum GitService {

    /// Maximum file names to retain per category for display.
    /// Counts are always accurate; only the name list is truncated.
    private static let maxFileNamesPerCategory = 50

    static func currentBranch(at repoPath: String) async throws -> String {
        let result = try await ShellExecutor.run(
            "git", arguments: ["branch", "--show-current"],
            workingDirectory: repoPath
        )
        return result.isEmpty ? "HEAD (detached)" : result
    }

    static func localStatus(at repoPath: String) async throws -> (staged: [String], modified: [String], untracked: [String], conflicts: [String]) {
        // Use -z so file names are NUL-delimited and never quoted/escaped.
        // Without -z, paths with spaces, newlines, or non-ASCII are wrapped in
        // quotes with C-style escapes that we'd have to undo by hand.
        let output = try await ShellExecutor.run(
            "git", arguments: ["status", "--porcelain=v1", "-z"],
            workingDirectory: repoPath
        )

        let parsed = parsePorcelainV1Z(output)
        return (
            capFiles(parsed.staged),
            capFiles(parsed.modified),
            capFiles(parsed.untracked),
            capFiles(parsed.conflicts)
        )
    }

    /// Pure parser for `git status --porcelain=v1 -z` output. Extracted so it
    /// can be unit-tested without shelling out. Returns uncapped lists.
    static func parsePorcelainV1Z(_ output: String) -> (
        staged: [String], modified: [String], untracked: [String], conflicts: [String]
    ) {
        guard !output.isEmpty else {
            return ([], [], [], [])
        }

        var staged: [String] = []
        var modified: [String] = []
        var untracked: [String] = []
        var conflicts: [String] = []

        // Split on NUL. The output ends with a trailing NUL, so the last entry
        // is empty — `omittingEmptySubsequences: false` keeps positions stable
        // for accurate pairing of rename entries; we skip empty entries below.
        let entries = output.split(
            separator: "\0",
            omittingEmptySubsequences: false
        ).map(String.init)

        var i = 0
        while i < entries.count {
            let entry = entries[i]
            if entry.count < 3 {
                i += 1
                continue
            }
            let chars = Array(entry)
            let x = chars[0]
            let y = chars[1]
            let displayName = String(entry.dropFirst(3))

            // Renames/copies emit two NUL-separated tokens: "XY new\0old\0".
            // The new name is what we want to display; consume the old name too.
            let isRenameOrCopy = (x == "R" || x == "C" || y == "R" || y == "C")

            if (x == "U" || y == "U") || (x == "A" && y == "A") || (x == "D" && y == "D") {
                conflicts.append(displayName)
            } else if x == "?" && y == "?" {
                untracked.append(displayName)
            } else {
                if x != " " && x != "?" { staged.append(displayName) }
                if y != " " && y != "?" { modified.append(displayName) }
            }

            i += isRenameOrCopy ? 2 : 1
        }

        return (staged, modified, untracked, conflicts)
    }

    private static func capFiles(_ files: [String]) -> [String] {
        guard files.count > maxFileNamesPerCategory else { return files }
        return Array(files.prefix(maxFileNamesPerCategory)) + ["... and \(files.count - maxFileNamesPerCategory) more"]
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
        let shortName = URL(fileURLWithPath: repoPath).lastPathComponent
        logger.debug("🌐 fetch START — \(shortName)")
        let start = CFAbsoluteTimeGetCurrent()
        _ = try await ShellExecutor.run(
            "git", arguments: ["fetch", "--all", "--prune"],
            workingDirectory: repoPath,
            timeout: 30
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        logger.debug("🌐 fetch DONE  — \(shortName) [\(String(format: "%.2f", elapsed))s]")
    }

    /// Pull with --ff-only. Fails if the merge isn't a fast-forward, so this
    /// never produces a surprise merge commit. Users wanting a merge or rebase
    /// pull should run it manually in their terminal.
    static func pull(at repoPath: String) async throws {
        let shortName = URL(fileURLWithPath: repoPath).lastPathComponent
        logger.debug("⬇️ pull START — \(shortName)")
        let start = CFAbsoluteTimeGetCurrent()
        _ = try await ShellExecutor.run(
            "git", arguments: ["pull", "--ff-only"],
            workingDirectory: repoPath,
            timeout: 60
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        logger.debug("⬇️ pull DONE  — \(shortName) [\(String(format: "%.2f", elapsed))s]")
    }

    /// Push the current branch to its tracked remote. No --force.
    static func push(at repoPath: String) async throws {
        let shortName = URL(fileURLWithPath: repoPath).lastPathComponent
        logger.debug("⬆️ push START — \(shortName)")
        let start = CFAbsoluteTimeGetCurrent()
        _ = try await ShellExecutor.run(
            "git", arguments: ["push"],
            workingDirectory: repoPath,
            timeout: 60
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        logger.debug("⬆️ push DONE  — \(shortName) [\(String(format: "%.2f", elapsed))s]")
    }

    /// Runs all status checks in parallel. Returns Result to never throw.
    static func fullStatus(at repoPath: String) async -> Result<GitRepoStatus, Error> {
        let shortName = URL(fileURLWithPath: repoPath).lastPathComponent
        let start = CFAbsoluteTimeGetCurrent()
        logger.debug("📋 fullStatus START — \(shortName)")

        do {
            // Run independent git commands in parallel
            async let branch = currentBranch(at: repoPath)
            async let local = localStatus(at: repoPath)
            async let remote = aheadBehind(at: repoPath)

            let branchName = try await branch
            let (staged, modified, untracked, conflicts) = try await local
            let (ahead, behind, hasTracking) = try await remote

            let elapsed = CFAbsoluteTimeGetCurrent() - start
            logger.debug("📋 fullStatus DONE  — \(shortName) branch=\(branchName) staged=\(staged.count) mod=\(modified.count) untracked=\(untracked.count) ahead=\(ahead) behind=\(behind) [\(String(format: "%.2f", elapsed))s]")

            let status = GitRepoStatus(
                branchName: branchName,
                stagedFiles: staged,
                modifiedFiles: modified,
                untrackedFiles: untracked,
                conflictFiles: conflicts,
                stagedCount: staged.count,
                modifiedCount: modified.count,
                untrackedCount: untracked.count,
                conflictCount: conflicts.count,
                aheadCount: ahead,
                behindCount: behind,
                hasRemoteTrackingBranch: hasTracking
            )
            return .success(status)
        } catch {
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            logger.error("📋 fullStatus FAIL  — \(shortName) [\(String(format: "%.2f", elapsed))s] \(error.localizedDescription)")
            return .failure(error)
        }
    }
}
