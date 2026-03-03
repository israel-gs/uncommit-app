import Foundation

struct RepoDiscoveryService {

    private static let skipDirectories: Set<String> = [
        "node_modules", ".build", "Pods", "build", "DerivedData",
        "vendor", "dist", ".next", "__pycache__", "venv", ".venv",
        "target", "out", "bin", "obj"
    ]

    func discoverRepositories(under rootPath: String, maxDepth: Int = 3) async -> [String] {
        var results: [String] = []
        scanDirectory(
            URL(fileURLWithPath: rootPath),
            currentDepth: 0,
            maxDepth: maxDepth,
            results: &results
        )
        return results.sorted()
    }

    private func scanDirectory(
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
            results.append(url.path)
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
            if Self.skipDirectories.contains(name) { continue }

            scanDirectory(
                child,
                currentDepth: currentDepth + 1,
                maxDepth: maxDepth,
                results: &results
            )
        }
    }
}
