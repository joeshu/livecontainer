import Foundation
import Security

struct LCCleanupReport {
    var removedItems: [String] = []
    var preservedItems: [String] = []
    var failures: [String] = []

    var didFail: Bool { !failures.isEmpty }

    var summary: String {
        var result = "Removed \(removedItems.count) item(s)."
        if !preservedItems.isEmpty {
            result += " Preserved \(preservedItems.count) shared or protected item(s)."
        }
        if !failures.isEmpty {
            result += " Failed \(failures.count) item(s)."
        }
        return result
    }
}

enum LCDataCleanupError: LocalizedError {
    case appIsRunning(String)
    case unsafePath(URL)
    case unsupportedTarget

    var errorDescription: String? {
        switch self {
        case .appIsRunning(let name):
            return "\(name) is currently running. Quit it before cleaning its data."
        case .unsafePath(let url):
            return "Refusing to clean an unsafe path: \(url.path)"
        case .unsupportedTarget:
            return "This target cannot be cleaned by LiveContainer."
        }
    }
}

/// Single source of truth for destructive data operations.
///
/// The service deliberately separates:
/// - deleting an app bundle;
/// - deleting a container's contents;
/// - deleting container-scoped credentials and legacy preferences; and
/// - deleting app-group data only when it is no longer referenced.
///
/// Every UI entry point should call this service instead of manipulating paths
/// directly. That keeps uninstall, container settings and data management
/// behavior identical.
final class LCDataCleanupService {
    static let shared = LCDataCleanupService()

    private let fileManager = FileManager.default

    private init() {}

    @discardableResult
    func uninstall(app: LCAppModel, deleteData: Bool) throws -> LCCleanupReport {
        let snapshot = try makeSnapshot(for: app)
        try ensureNotRunning(snapshot)

        guard let bundlePath = snapshot.bundlePath else {
            throw CocoaError(.fileNoSuchFile)
        }
        try removeBundle(at: bundlePath)

        var report = LCCleanupReport()
        report.removedItems.append("App bundle")

        if deleteData {
            report.merge(cleanData(for: snapshot, removeContainerDefinitions: true, removeAppGroups: true))
            removeUnusedTweakFolder(snapshot.tweakFolder, excluding: snapshot.app, report: &report)
        } else {
            report.preservedItems.append("Container data")
        }

        clearRuntimeState(for: snapshot)
        return report
    }

    @discardableResult
    func reset(app: LCAppModel) throws -> LCCleanupReport {
        let snapshot = try makeSnapshot(for: app)
        try ensureNotRunning(snapshot)

        var report = cleanData(
            for: snapshot,
            removeContainerDefinitions: false,
            removeAppGroups: snapshot.containers.count == 1
        )
        if snapshot.containers.count > 1 {
            report.preservedItems.append("Shared App Group data used by multiple containers")
        }
        clearRuntimeState(for: snapshot)
        return report
    }

    @discardableResult
    func delete(container: LCContainer, from app: LCAppModel, removeDefinition: Bool) throws -> LCCleanupReport {
        let snapshot = try makeSnapshot(for: app, containers: [container])
        try ensureNotRunning(snapshot)

        var report = LCCleanupReport()
        cleanContainer(container, keepInfoPlist: !removeDefinition, report: &report)
        cleanContainerMetadata(container.folderName, report: &report)

        if removeDefinition {
            clearRuntimeState(for: snapshot)
        }

        // A single-container reset can safely remove exclusive app groups. A
        // multi-container app keeps shared groups to avoid cross-container data loss.
        if removeDefinition || app.uiContainers.count == 1 {
            removeUnusedAppGroups(
                snapshot.groupIdentifiers,
                excluding: removeDefinition ? app : nil,
                report: &report
            )
        } else {
            report.preservedItems.append("Shared App Group data")
        }
        return report
    }

    @discardableResult
    func cleanKeychain(for container: LCContainer, app: LCAppModel) throws -> LCCleanupReport {
        let snapshot = try makeSnapshot(for: app, containers: [container])
        try ensureNotRunning(snapshot)

        var report = LCCleanupReport()
        guard !container.folderName.isEmpty else {
            report.preservedItems.append("Container without a data identifier")
            return report
        }
        LCUtils.removeAppKeychain(dataUUID: container.folderName)
        report.removedItems.append("Keychain namespace \(container.folderName)")
        return report
    }

    @discardableResult
    func cleanKeychains(for apps: [LCAppModel]) -> LCCleanupReport {
        var report = LCCleanupReport()
        for app in apps where !(app.appInfo is BuiltInSideStoreAppInfo) {
            for container in app.uiContainers where !container.folderName.isEmpty {
                if let usingLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) {
                    report.preservedItems.append("\(app.displayName) (\(usingLC))")
                    continue
                }
                LCUtils.removeAppKeychain(dataUUID: container.folderName)
                report.removedItems.append("Keychain namespace \(container.folderName)")
            }
        }
        return report
    }

    func orphanedContainerCount(apps: [LCAppModel], hiddenApps: [LCAppModel]) -> Int {
        let usedNames = Set((apps + hiddenApps).flatMap { $0.appInfo.containers.map(\.folderName) })
        var count = 0
        for root in [LCPath.dataPath, LCPath.lcGroupDataPath] {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            count += entries.filter { !usedNames.contains($0.lastPathComponent) }.count
        }
        return count
    }

    @discardableResult
    func clearTemporaryFiles() -> LCCleanupReport {
        var report = LCCleanupReport()
        clearDirectoryContents(
            at: fileManager.temporaryDirectory,
            preserving: [],
            report: &report
        )
        return report
    }

    @discardableResult
    func clearCaches(for apps: [LCAppModel], hiddenApps: [LCAppModel]) -> LCCleanupReport {
        var report = LCCleanupReport()
        var allApps = apps + hiddenApps
        if UserDefaults.sideStoreExist() {
            allApps.append(LCAppModel(appInfo: BuiltInSideStoreAppInfo.shared))
        }

        for app in allApps {
            if app.isAppRunning {
                report.preservedItems.append("\(app.displayName) is running")
                continue
            }
            for container in app.uiContainers {
                if let usingLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) {
                    report.preservedItems.append("\(app.displayName) (\(usingLC))")
                    continue
                }
                clearContainerCaches(container, report: &report)
            }
        }

        if let hostCaches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            clearDirectoryContents(at: hostCaches, preserving: [], report: &report)
        }
        return report
    }

    @discardableResult
    func removeOrphanedContainers(apps: [LCAppModel], hiddenApps: [LCAppModel]) -> LCCleanupReport {
        let usedNames = Set((apps + hiddenApps).flatMap { $0.appInfo.containers.map(\.folderName) })
        var report = LCCleanupReport()

        for root in [LCPath.dataPath, LCPath.lcGroupDataPath] {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for url in entries where !usedNames.contains(url.lastPathComponent) {
                guard isDescendant(url, of: root) else {
                    report.failures.append("Unsafe orphan path: \(url.path)")
                    continue
                }
                do {
                    try fileManager.removeItem(at: url)
                    report.removedItems.append(url.path)
                    cleanContainerMetadata(url.lastPathComponent, report: &report)
                } catch {
                    report.failures.append("\(url.path): \(error.localizedDescription)")
                }
            }
        }
        return report
    }

    private struct Snapshot {
        let app: LCAppModel
        let appInfo: LCAppInfo
        let bundlePath: URL?
        let relativeBundlePath: String?
        let containers: [LCContainer]
        let groupIdentifiers: Set<String>
        let urlSchemes: Set<String>
        let tweakFolder: String?
    }

    private func makeSnapshot(for app: LCAppModel, containers: [LCContainer]? = nil) throws -> Snapshot {
        let appInfo = app.appInfo
        if appInfo is BuiltInSideStoreAppInfo {
            throw LCDataCleanupError.unsupportedTarget
        }

        let selectedContainers = containers ?? appInfo.containers
        return Snapshot(
            app: app,
            appInfo: appInfo,
            bundlePath: appInfo.bundlePath().map { URL(fileURLWithPath: $0) },
            relativeBundlePath: appInfo.relativeBundlePath,
            containers: selectedContainers,
            groupIdentifiers: applicationGroupIdentifiers(for: appInfo),
            urlSchemes: Set((appInfo.urlSchemes() as? [String]) ?? []),
            tweakFolder: appInfo.tweakFolder
        )
    }

    private func ensureNotRunning(_ snapshot: Snapshot) throws {
        if snapshot.app.isAppRunning {
            throw LCDataCleanupError.appIsRunning(snapshot.app.displayName)
        }
        for container in snapshot.containers {
            if let usingLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) {
                throw LCDataCleanupError.appIsRunning(usingLC)
            }
        }
    }

    private func removeBundle(at url: URL) throws {
        let roots = [LCPath.bundlePath, LCPath.lcGroupBundlePath]
        guard roots.contains(where: { isDescendant(url, of: $0) }) else {
            throw LCDataCleanupError.unsafePath(url)
        }
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try fileManager.removeItem(at: url)
    }

    private func cleanData(
        for snapshot: Snapshot,
        removeContainerDefinitions: Bool,
        removeAppGroups: Bool
    ) -> LCCleanupReport {
        var report = LCCleanupReport()
        for container in snapshot.containers {
            cleanContainer(
                container,
                keepInfoPlist: !removeContainerDefinitions,
                report: &report
            )
            cleanContainerMetadata(container.folderName, report: &report)
        }

        if removeAppGroups {
            removeUnusedAppGroups(snapshot.groupIdentifiers, excluding: snapshot.app, report: &report)
        } else if !snapshot.groupIdentifiers.isEmpty {
            report.preservedItems.append("Shared App Group data")
        }
        return report
    }

    private func cleanContainer(
        _ container: LCContainer,
        keepInfoPlist: Bool,
        report: inout LCCleanupReport
    ) {
        let url = container.containerURL.standardizedFileURL
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        let isExternal = container.storageBookMark != nil
        if !isExternal && !isDescendant(url, of: LCPath.dataPath) && !isDescendant(url, of: LCPath.lcGroupDataPath) {
            report.failures.append(LCDataCleanupError.unsafePath(url).localizedDescription)
            return
        }

        var accessed = false
        if isExternal {
            accessed = url.startAccessingSecurityScopedResource()
        }
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            if isExternal || keepInfoPlist {
                let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                for item in contents where !(keepInfoPlist && item.lastPathComponent == "LCContainerInfo.plist") {
                    try fileManager.removeItem(at: item)
                    report.removedItems.append(item.path)
                }
            } else {
                try fileManager.removeItem(at: url)
                report.removedItems.append(url.path)
            }
        } catch {
            report.failures.append("\(url.path): \(error.localizedDescription)")
        }
    }

    private func cleanContainerMetadata(_ dataUUID: String, report: inout LCCleanupReport) {
        guard !dataUUID.isEmpty else { return }
        LCUtils.removeAppKeychain(dataUUID: dataUUID)
        LCSharedUtils.removeLegacyPreferences(forDataUUID: dataUUID)
        DataManager.shared.model.appDataFolderNames.removeAll { $0 == dataUUID }
    }

    private func clearDirectoryContents(
        at url: URL,
        preserving: Set<String>,
        report: inout LCCleanupReport
    ) {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        do {
            let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            for item in contents where !preserving.contains(item.lastPathComponent) {
                do {
                    try fileManager.removeItem(at: item)
                    report.removedItems.append(item.path)
                } catch {
                    report.failures.append("\(item.path): \(error.localizedDescription)")
                }
            }
        } catch {
            report.failures.append("\(url.path): \(error.localizedDescription)")
        }
    }

    private func clearContainerCaches(_ container: LCContainer, report: inout LCCleanupReport) {
        let containerURL = container.containerURL.standardizedFileURL
        let isExternal = container.storageBookMark != nil
        if !isExternal &&
            !isDescendant(containerURL, of: LCPath.dataPath) &&
            !isDescendant(containerURL, of: LCPath.lcGroupDataPath) {
            report.failures.append(LCDataCleanupError.unsafePath(containerURL).localizedDescription)
            return
        }

        var accessed = false
        if isExternal {
            accessed = containerURL.startAccessingSecurityScopedResource()
        }
        defer {
            if accessed {
                containerURL.stopAccessingSecurityScopedResource()
            }
        }

        let cacheURL = containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
        guard isDescendant(cacheURL, of: containerURL) else {
            report.failures.append(LCDataCleanupError.unsafePath(cacheURL).localizedDescription)
            return
        }
        clearDirectoryContents(at: cacheURL, preserving: [], report: &report)
    }

    private func removeUnusedAppGroups(
        _ groupIdentifiers: Set<String>,
        excluding removedApp: LCAppModel?,
        report: inout LCCleanupReport
    ) {
        guard !groupIdentifiers.isEmpty else { return }

        var remainingApps = DataManager.shared.model.apps + DataManager.shared.model.hiddenApps
        if let removedApp {
            remainingApps.removeAll { $0 === removedApp }
        }
        if UserDefaults.sideStoreExist() {
            remainingApps.append(LCAppModel(appInfo: BuiltInSideStoreAppInfo.shared))
        }

        var usedGroups = Set<String>()
        for app in remainingApps {
            usedGroups.formUnion(applicationGroupIdentifiers(for: app.appInfo))
        }

        for group in groupIdentifiers.subtracting(usedGroups) {
            guard isSafePathComponent(group) else {
                report.failures.append("Unsafe App Group identifier: \(group)")
                continue
            }
            for root in [LCPath.appGroupPath, LCPath.lcGroupAppGroupPath] {
                let url = root.appendingPathComponent(group, isDirectory: true)
                guard isDescendant(url, of: root), fileManager.fileExists(atPath: url.path) else {
                    continue
                }
                do {
                    try fileManager.removeItem(at: url)
                    report.removedItems.append(url.path)
                } catch {
                    report.failures.append("\(url.path): \(error.localizedDescription)")
                }
            }
        }
    }

    private func removeUnusedTweakFolder(
        _ folder: String?,
        excluding removedApp: LCAppModel,
        report: inout LCCleanupReport
    ) {
        guard let folder, !folder.isEmpty, folder != "TweakLoader.dylib", isSafePathComponent(folder) else {
            return
        }
        let remainingApps = (DataManager.shared.model.apps + DataManager.shared.model.hiddenApps)
            .filter { $0 !== removedApp }
        if remainingApps.contains(where: { $0.appInfo.tweakFolder == folder }) {
            report.preservedItems.append("Shared tweak folder \(folder)")
            return
        }
        for root in [LCPath.tweakPath, LCPath.lcGroupTweakPath] {
            let url = root.appendingPathComponent(folder, isDirectory: true)
            guard isDescendant(url, of: root), fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try fileManager.removeItem(at: url)
                report.removedItems.append(url.path)
            } catch {
                report.failures.append("\(url.path): \(error.localizedDescription)")
            }
        }
    }

    private func clearRuntimeState(for snapshot: Snapshot) {
        let defaults = UserDefaults.standard
        if let selected = defaults.string(forKey: "selected"), selected == snapshot.relativeBundlePath {
            defaults.removeObject(forKey: "selected")
        }
        if let selectedContainer = defaults.string(forKey: "selectedContainer"),
           snapshot.containers.contains(where: { $0.folderName == selectedContainer }) {
            defaults.removeObject(forKey: "selectedContainer")
        }
        if let launchURL = defaults.string(forKey: "launchAppUrlScheme"),
           let scheme = URL(string: launchURL)?.scheme,
           snapshot.urlSchemes.contains(scheme) {
            defaults.removeObject(forKey: "launchAppUrlScheme")
        }

        if let sharedDefaults = UserDefaults.lcShared(),
           var guestSchemes = sharedDefaults.array(forKey: "LCGuestURLSchemes") as? [String] {
            guestSchemes.removeAll { snapshot.urlSchemes.contains($0) }
            sharedDefaults.set(guestSchemes, forKey: "LCGuestURLSchemes")
        }

        let appGroupDefaults = LCUtils.appGroupUserDefault
        if appGroupDefaults.string(forKey: "LCLaunchExtensionBundleID") == snapshot.relativeBundlePath {
            [
                "LCLaunchExtensionBundleID",
                "LCLaunchExtensionContainerName",
                "LCLaunchExtensionLaunchURL",
                "LCLaunchExtensionLaunchDate"
            ].forEach { appGroupDefaults.removeObject(forKey: $0) }
        }
        if let bundleIdentifier = snapshot.appInfo.bundleIdentifier(),
           let relativeBundlePath = snapshot.relativeBundlePath,
           var customOrder = appGroupDefaults.array(forKey: "LCCustomSortOrder") as? [String] {
            let identifier = "\(bundleIdentifier):\(relativeBundlePath)"
            customOrder.removeAll { $0 == identifier }
            appGroupDefaults.set(customOrder, forKey: "LCCustomSortOrder")
        }
    }

    private func applicationGroupIdentifiers(for appInfo: LCAppInfo) -> Set<String> {
        guard let bundlePath = appInfo.bundlePath(),
              let info = NSDictionary(contentsOfFile: "\(bundlePath)/Info.plist"),
              let executable = info["CFBundleExecutable"] as? String else {
            return []
        }
        let executablePath = "\(bundlePath)/\(executable)"
        guard let entitlementXML = getExecutableEntitlementXML(executablePath),
              let data = entitlementXML.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let entitlements = plist as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String] else {
            return []
        }
        return Set(groups.filter { isSafePathComponent($0) })
    }

    private func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\")
    }

    private func isDescendant(_ url: URL, of root: URL) -> Bool {
        let child = url.standardizedFileURL.path
        let parent = root.standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return child == "/\(parent)" || child.hasPrefix("/\(parent)/")
    }
}

private extension LCCleanupReport {
    mutating func merge(_ other: LCCleanupReport) {
        removedItems.append(contentsOf: other.removedItems)
        preservedItems.append(contentsOf: other.preservedItems)
        failures.append(contentsOf: other.failures)
    }
}
