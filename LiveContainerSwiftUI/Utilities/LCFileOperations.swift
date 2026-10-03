import Foundation

enum LCFileOperations {
    static func directories(in root: URL, fileManager: FileManager = .default) throws -> [URL] {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func bundleIdentifier(in bundle: URL) throws -> String {
        let data = try Data(contentsOf: bundle.appendingPathComponent("Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        guard let identifier = info?["CFBundleIdentifier"] as? String, !identifier.isEmpty,
              !identifier.contains("/"), !identifier.contains("\\"),
              identifier.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return identifier
    }

    /// Keep the previous bundle until the replacement has actually moved into
    /// place. A move failure restores it; cleanup failure does not undo success.
    static func installBundle(from source: URL, to destination: URL, replacing: Bool,
                              fileManager: FileManager = .default) throws {
        guard replacing && fileManager.fileExists(atPath: destination.path) else {
            try fileManager.moveItem(at: source, to: destination)
            return
        }
        let backup = destination.deletingLastPathComponent()
            .appendingPathComponent(".LCInstallBackup-" + UUID().uuidString, isDirectory: true)
        try fileManager.moveItem(at: destination, to: backup)
        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            do { try fileManager.moveItem(at: backup, to: destination) }
            catch { throw NSError(domain: "LCBundleReplacement", code: 1, userInfo: [NSUnderlyingErrorKey: error]) }
            throw error
        }
        do { try fileManager.removeItem(at: backup) }
        catch { NSLog("[LC] Replacement succeeded; backup cleanup failed: %@", error.localizedDescription) }
    }
}
