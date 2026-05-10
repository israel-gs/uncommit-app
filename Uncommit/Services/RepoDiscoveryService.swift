import Foundation

struct RepoDiscoveryService: Sendable {

    private static let skipDirectories: Set<String> = [
        "node_modules", ".build", "Pods", "build", "DerivedData",
        "vendor", "dist", ".next", "__pycache__", "venv", ".venv",
        "target", "out", "bin", "obj"
    ]

    func discoverRepositories(under rootPath: String, maxDepth: Int = 3) async -> [String] {
        // Run the recursive filesystem scan on a detached task so deep trees
        // don't block the cooperative thread pool that other async work uses.
        await Task.detached(priority: .userInitiated) {
            var results: [String] = []
            Self.scanDirectory(
                URL(fileURLWithPath: rootPath),
                currentDepth: 0,
                maxDepth: maxDepth,
                results: &results
            )
            return results.sorted()
        }.value
    }

    private static func scanDirectory(
        _ url: URL,
        currentDepth: Int,
        maxDepth: Int,
        results: inout [String]
    ) {
        guard currentDepth <= maxDepth else { return }

        let fileManager = FileManager.default
        let gitDir = url.appendingPathComponent(".git")

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: gitDir.path, isDirectory: &isDirectory) {
            // Resolve symlinks so paths always match the canonical form
            // used by AppViewModel (prevents "Checking..." stuck states).
            results.append(url.resolvingSymlinksInPath().path)
            return // Don't descend into git repos
        }

        guard let contents = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        for child in contents {
            guard let resourceValues = try? child.resourceValues(forKeys: [.isDirectoryKey]),
                  resourceValues.isDirectory == true else { continue }

            let name = child.lastPathComponent
            if skipDirectories.contains(name) { continue }

            scanDirectory(
                child,
                currentDepth: currentDepth + 1,
                maxDepth: maxDepth,
                results: &results
            )
        }
    }
}
