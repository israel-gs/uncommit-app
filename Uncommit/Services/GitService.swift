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

    /// Parsed working-tree status. File buckets are display-capped; submodules
    /// are never capped (they're rare and few).
    struct LocalStatus: Equatable {
        var staged: [String] = []
        var modified: [String] = []
        var untracked: [String] = []
        var conflicts: [String] = []
        var submodules: [SubmoduleChange] = []
    }

    static func localStatus(at repoPath: String) async throws -> LocalStatus {
        // porcelain=v2 carries a per-entry submodule field (`N...` vs `S<c><m><u>`)
        // that v1 lacks, letting us tell a submodule pointer change apart from a
        // plain modified file. -z keeps paths NUL-delimited and never C-escaped.
        let output = try await ShellExecutor.run(
            "git", arguments: ["status", "--porcelain=v2", "-z"],
            workingDirectory: repoPath
        )

        var parsed = parsePorcelainV2Z(output)
        parsed.staged = capFiles(parsed.staged)
        parsed.modified = capFiles(parsed.modified)
        parsed.untracked = capFiles(parsed.untracked)
        parsed.conflicts = capFiles(parsed.conflicts)
        return parsed
    }

    /// Pure parser for `git status --porcelain=v2 -z` output. Extracted so it
    /// can be unit-tested without shelling out. Returns uncapped lists.
    ///
    /// Record forms (each NUL-terminated; `-z` is assumed):
    ///   `1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>`        ordinary change
    ///   `2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <Xscore> <path>\0<orig>`  rename/copy
    ///   `u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>`         unmerged
    ///   `? <path>` untracked   `! <path>` ignored
    /// `<sub>` is `N...` for a normal path or `S<c><m><u>` for a submodule,
    /// where c=commit changed, m=modified content, u=untracked content.
    static func parsePorcelainV2Z(_ output: String) -> LocalStatus {
        var result = LocalStatus()
        guard !output.isEmpty else { return result }

        // Trailing NUL yields an empty final token; keep positions stable so a
        // rename's two tokens pair correctly, and skip empties below.
        let tokens = output.split(
            separator: "\0",
            omittingEmptySubsequences: false
        ).map(String.init)

        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            guard let marker = token.first else { i += 1; continue }
            switch marker {
            case "1":
                classifyChanged(token, fieldCount: 8, into: &result)
                i += 1
            case "2":
                // Rename/copy: the new name lives in this token (9 fields before
                // it); the original name is the NEXT token — consume it too.
                classifyChanged(token, fieldCount: 9, into: &result)
                i += 2
            case "u":
                if let path = pathAfterFields(token, fieldCount: 10) {
                    result.conflicts.append(path)
                }
                i += 1
            case "?":
                if let path = pathAfterFields(token, fieldCount: 1) {
                    result.untracked.append(path)
                }
                i += 1
            default:
                // "!" ignored entries and any header line — skip.
                i += 1
            }
        }

        return result
    }

    /// Splits a porcelain v2 record into its leading space-separated header
    /// fields and the trailing path. `fieldCount` is the number of fields that
    /// precede the path (e.g. 8 for `1` records). Returns nil if the record is
    /// malformed (fewer fields than expected).
    private static func splitFields(_ token: String, count: Int) -> (fields: [String], path: String)? {
        let parts = token.split(
            separator: " ",
            maxSplits: count,
            omittingEmptySubsequences: false
        ).map(String.init)
        guard parts.count == count + 1 else { return nil }
        return (Array(parts.prefix(count)), parts[count])
    }

    private static func pathAfterFields(_ token: String, fieldCount: Int) -> String? {
        splitFields(token, count: fieldCount)?.path
    }

    /// Classifies an ordinary (`1`) or rename/copy (`2`) record. Submodules are
    /// routed to their own bucket; everything else is split into staged/modified
    /// by the two-character XY status (v2 uses '.' for "unmodified").
    private static func classifyChanged(_ token: String, fieldCount: Int, into result: inout LocalStatus) {
        guard let (fields, path) = splitFields(token, count: fieldCount) else { return }
        let xy = Array(fields[1])
        let sub = fields[2]
        guard xy.count == 2 else { return }
        let x = xy[0]  // index (staged) status
        let y = xy[1]  // worktree status

        if sub.first == "S" {
            let flags = Array(sub)  // ["S", c, m, u]
            result.submodules.append(SubmoduleChange(
                name: path,
                commitChanged: flags.count > 1 && flags[1] == "C",
                hasModifications: flags.count > 2 && flags[2] == "M",
                hasUntracked: flags.count > 3 && flags[3] == "U",
                staged: x != "."
            ))
            return
        }

        if x != "." { result.staged.append(path) }
        if y != "." { result.modified.append(path) }
    }

    /// Fills in branch + old/new SHA for changed submodules. Skipped entirely
    /// when there are none, so the common (no-submodule) repo pays nothing.
    /// Each enrichment is best-effort: an uninitialized or newly-added submodule
    /// simply leaves the missing fields nil.
    static func enrichSubmodules(_ submodules: [SubmoduleChange], parentPath: String) async -> [SubmoduleChange] {
        guard !submodules.isEmpty else { return [] }
        var enriched: [SubmoduleChange] = []
        for var sm in submodules {
            // Old (recorded) SHA from the parent's committed tree.
            sm.oldSHA = try? await ShellExecutor.run(
                "git", arguments: ["rev-parse", "--short", "HEAD:\(sm.name)"],
                workingDirectory: parentPath
            )
            // New SHA + branch from the submodule's own working tree. These are
            // two separate rev-parse calls on purpose: combining `--short HEAD`
            // and `--abbrev-ref HEAD` in one invocation fails ("Needed a single
            // revision"). `--abbrev-ref` returns "HEAD" for a detached submodule,
            // which is git's NORMAL state for a submodule (it tracks a commit,
            // not a branch) — we map that to nil.
            let subWorkdir = parentPath + "/" + sm.name
            sm.newSHA = try? await ShellExecutor.run(
                "git", arguments: ["rev-parse", "--short", "HEAD"],
                workingDirectory: subWorkdir
            )
            if let ref = try? await ShellExecutor.run(
                "git", arguments: ["rev-parse", "--abbrev-ref", "HEAD"],
                workingDirectory: subWorkdir
            ) {
                sm.branch = ref == "HEAD" ? nil : ref
            }
            enriched.append(sm)
        }
        return enriched
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

    /// Lists commits in a revision range, newest first. Used to show what's
    /// pending push (`@{u}..HEAD`) or pull (`HEAD..@{u}`). Fields are split on
    /// the unit-separator (0x1f) so subjects with any punctuation survive.
    static func commits(at repoPath: String, range: String, limit: Int = 30) async throws -> [GitCommit] {
        let output = try await ShellExecutor.run(
            "git",
            arguments: ["log", range, "--format=%h%x1f%s%x1f%an%x1f%ar", "-n", "\(limit)"],
            workingDirectory: repoPath
        )
        guard !output.isEmpty else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let f = line.components(separatedBy: "\u{1f}")
            guard f.count == 4 else { return nil }
            return GitCommit(hash: f[0], subject: f[1], author: f[2], relativeDate: f[3])
        }
    }

    /// Local branches plus remote-only branches (those on a remote with no local
    /// counterpart). Checking one out creates the local tracking branch. Remote
    /// names are stripped of their remote prefix ("origin/dev" → "dev") and the
    /// remote's symbolic HEAD is dropped.
    static func branches(at repoPath: String) async throws -> (local: [String], remoteOnly: [String]) {
        let localOut = try await ShellExecutor.run(
            "git", arguments: ["branch", "--format=%(refname:short)"],
            workingDirectory: repoPath
        )
        let local = localOut.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let localSet = Set(local)

        let remoteOut = (try? await ShellExecutor.run(
            "git", arguments: ["branch", "-r", "--format=%(refname:short)"],
            workingDirectory: repoPath
        )) ?? ""

        var remoteOnly: [String] = []
        for ref in remoteOut.split(separator: "\n").map(String.init) {
            // Drop "origin/HEAD" (the remote's symbolic default pointer).
            if ref.hasSuffix("/HEAD") { continue }
            // Strip the remote name: "origin/feature/x" → "feature/x".
            guard let slash = ref.firstIndex(of: "/") else { continue }
            let short = String(ref[ref.index(after: slash)...])
            if !short.isEmpty, !localSet.contains(short), !remoteOnly.contains(short) {
                remoteOnly.append(short)
            }
        }
        return (local, remoteOnly)
    }

    /// Switches to an existing local branch. Fails (and surfaces git's message)
    /// when the working tree has changes that the checkout would overwrite.
    static func checkout(at repoPath: String, branch: String) async throws {
        _ = try await ShellExecutor.run(
            "git", arguments: ["checkout", branch],
            workingDirectory: repoPath,
            timeout: 30
        )
    }

    /// Checks the submodule out to the exact commit the parent records, clearing
    /// a "commit changed" divergence. Runs in the PARENT repo. Fails loudly if
    /// the submodule has local changes the checkout would overwrite.
    static func updateSubmodule(at parentPath: String, submodule: String) async throws {
        _ = try await ShellExecutor.run(
            "git", arguments: ["submodule", "update", "--", submodule],
            workingDirectory: parentPath,
            timeout: 60
        )
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
            let localStatus = try await local
            let (ahead, behind, hasTracking) = try await remote

            // Only touches disk when the repo actually has changed submodules.
            let submodules = await enrichSubmodules(localStatus.submodules, parentPath: repoPath)

            let elapsed = CFAbsoluteTimeGetCurrent() - start
            logger.debug("📋 fullStatus DONE  — \(shortName) branch=\(branchName) staged=\(localStatus.staged.count) mod=\(localStatus.modified.count) untracked=\(localStatus.untracked.count) submodules=\(submodules.count) ahead=\(ahead) behind=\(behind) [\(String(format: "%.2f", elapsed))s]")

            let status = GitRepoStatus(
                branchName: branchName,
                stagedFiles: localStatus.staged,
                modifiedFiles: localStatus.modified,
                untrackedFiles: localStatus.untracked,
                conflictFiles: localStatus.conflicts,
                stagedCount: localStatus.staged.count,
                modifiedCount: localStatus.modified.count,
                untrackedCount: localStatus.untracked.count,
                conflictCount: localStatus.conflicts.count,
                aheadCount: ahead,
                behindCount: behind,
                hasRemoteTrackingBranch: hasTracking,
                submodules: submodules
            )
            return .success(status)
        } catch {
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            logger.error("📋 fullStatus FAIL  — \(shortName) [\(String(format: "%.2f", elapsed))s] \(error.localizedDescription)")
            return .failure(error)
        }
    }
}
