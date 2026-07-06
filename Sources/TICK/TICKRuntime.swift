import Foundation

enum TICKRuntime {
    static var rootURL: URL {
        migrateLegacyDataIfNeeded()
        let url = resolvedRootURL()
        ensureDirectory(url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    static var toolsURL: URL {
        let url = rootURL.appendingPathComponent("tools", isDirectory: true)
        ensureDirectory(url)
        return url
    }

    static func ensureDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private static var didMigrateLegacyData = false

    private static func resolvedRootURL() -> URL {
        if let configuredPath = ProcessInfo.processInfo.environment["TICK_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configuredPath.isEmpty {
            return URL(fileURLWithPath: configuredPath, isDirectory: true)
                .standardizedFileURL
        }

        if let sourceRoot = sourceDerivedRootURL() {
            return sourceRoot
        }

        if let bundleRoot = bundleDerivedRootURL() {
            return bundleRoot
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("TICK", isDirectory: true)
    }

    private static func sourceDerivedRootURL() -> URL? {
        let sourcePath = #filePath
        guard sourcePath.hasPrefix("/") else {
            return nil
        }

        let sourceFile = URL(fileURLWithPath: sourcePath)
        let projectRoot = sourceFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return tickRoot(forProjectRoot: projectRoot)
    }

    private static func bundleDerivedRootURL() -> URL? {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            return nil
        }

        let appParent = bundleURL.deletingLastPathComponent()
        guard appParent.lastPathComponent == "dist" else {
            return nil
        }

        let projectRoot = appParent.deletingLastPathComponent()
        return tickRoot(forProjectRoot: projectRoot)
    }

    private static func tickRoot(forProjectRoot projectRoot: URL) -> URL {
        if projectRoot.lastPathComponent == "TICK" {
            return projectRoot.standardizedFileURL
        }

        return projectRoot
            .deletingLastPathComponent()
            .appendingPathComponent("TICK", isDirectory: true)
            .standardizedFileURL
    }

    private static func migrateLegacyDataIfNeeded() {
        guard !didMigrateLegacyData else {
            return
        }
        didMigrateLegacyData = true

        let destination = resolvedRootURL()
        ensureDirectory(destination)

        let legacy = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TICK", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: legacy.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              legacy.standardizedFileURL != destination.standardizedFileURL else {
            return
        }

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: legacy,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        for entry in entries {
            let target = destination.appendingPathComponent(entry.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: target.path) else {
                continue
            }
            try? FileManager.default.copyItem(at: entry, to: target)
        }
    }
}
