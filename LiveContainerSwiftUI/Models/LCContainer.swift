//
//  LCAppInfo.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/12/5.
//

import Foundation

/// Owns a security-scoped access session for the lifetime of a settings view.
/// Passing the URL without this owner would leave external-container access
/// dependent on whichever caller last started the scope.
final class LCContainerAccess {
    let url: URL
    private let needsStop: Bool

    init?(container: LCContainer) {
        guard container.hasUsableStorage else { return nil }
        let url = container.containerURL
        let needsStop = container.storageBookMark != nil
        if needsStop && !url.startAccessingSecurityScopedResource() {
            return nil
        }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            if needsStop { url.stopAccessingSecurityScopedResource() }
            return nil
        }
        do {
            let preferencesURL = url.appendingPathComponent("Library/Preferences", isDirectory: true)
            if !FileManager.default.fileExists(atPath: preferencesURL.path) {
                try FileManager.default.createDirectory(at: preferencesURL,
                                                        withIntermediateDirectories: true)
            }
        } catch {
            if needsStop { url.stopAccessingSecurityScopedResource() }
            return nil
        }
        self.url = url
        self.needsStop = needsStop
    }

    deinit {
        if needsStop {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

class LCContainer : ObservableObject, Hashable {
    @Published var folderName : String
    @Published var name : String
    @Published var isShared : Bool
    
    @Published var storageBookMark: Data?
    @Published var resolvedContainerURL: URL?
    @Published var bookmarkResolved = false
    @Published var bookmarkIsStale = false
    var bookmarkResolveContinuation: UnsafeContinuation<(), Never>? = nil
    
    @Published var isolateAppGroup : Bool

    @Published var spoofIdentifierForVendor : Bool {
        didSet {
            if spoofIdentifierForVendor && spoofedIdentifier == nil {
                spoofedIdentifier = UUID().uuidString
            }
        }
    }
    public var spoofedIdentifier: String?
    private var infoDict : [String:Any]?
    public var hasUsableStorage: Bool {
        let safeFolderName = folderName.isSafePathComponent() ||
            (folderName.isEmpty && resolvedContainerURL != nil && storageBookMark == nil)
        return safeFolderName && (storageBookMark == nil || resolvedContainerURL != nil)
    }

    private func withContainerAccess<T>(_ body: (URL) throws -> T) throws -> T {
        guard let url = resolvedContainerURL ?? (storageBookMark == nil ? containerURL : nil) else {
            throw NSError(domain: "LiveContainer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Container bookmark is unavailable"])
        }
        let accessed = storageBookMark == nil || url.startAccessingSecurityScopedResource()
        guard accessed else {
            throw NSError(domain: "LiveContainer", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Unable to access container bookmark"])
        }
        defer {
            if storageBookMark != nil {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try body(url)
    }

    private func readInfoDict() -> [String: Any]? {
        do {
            return try withContainerAccess { url in
                NSDictionary(contentsOf: url.appendingPathComponent("LCContainerInfo.plist")) as? [String: Any]
            }
        } catch {
            return nil
        }
    }

    private func validateExternalMetadata(at url: URL, expectedAppIdentifier: String) throws {
        let metadataURL = url.appendingPathComponent("LCContainerInfo.plist")
        guard let metadata = NSDictionary(contentsOf: metadataURL) as? [String: Any],
              metadata["appIdentifier"] as? String == expectedAppIdentifier else {
            throw NSError(domain: "LiveContainer", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Container metadata owner mismatch"])
        }
        if let metadataFolderName = metadata["folderName"] as? String {
            guard metadataFolderName == folderName else {
                throw NSError(domain: "LiveContainer", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "Container metadata identity mismatch"])
            }
        } else {
            // Older metadata did not persist folderName. The registered name
            // must still match the bookmark target's final directory component.
            guard url.lastPathComponent == folderName else {
                throw NSError(domain: "LiveContainer", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "Legacy container identity mismatch"])
            }
        }
    }

    func validateExternalOwnership(appInfo: LCAppInfo) throws {
        guard storageBookMark != nil else { return }
        guard let appIdentifier = appInfo.bundleIdentifier() else {
            throw NSError(domain: "LiveContainer", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "Unable to determine container owner"])
        }
        try withContainerAccess { url in
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw NSError(domain: "LiveContainer", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Container bookmark must resolve to a directory"])
            }
            try validateExternalMetadata(at: url, expectedAppIdentifier: appIdentifier)
        }
    }

    func renewStaleBookmarkIfNeeded(appInfo: LCAppInfo) throws {
        guard storageBookMark != nil, bookmarkIsStale else { return }
        guard let appIdentifier = appInfo.bundleIdentifier() else {
            throw NSError(domain: "LiveContainer", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "Unable to determine container owner"])
        }

        let renewedBookmark = try withContainerAccess { url in
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw NSError(domain: "LiveContainer", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Container bookmark must resolve to a directory"])
            }
            try validateExternalMetadata(at: url, expectedAppIdentifier: appIdentifier)
            return try url.bookmarkData(options: URL.BookmarkCreationOptions(rawValue: 1 << 11),
                                        includingResourceValuesForKeys: nil,
                                        relativeTo: nil)
        }

        guard var records = appInfo.containerInfo as? [[String: Any]],
              let index = records.firstIndex(where: { $0["folderName"] as? String == folderName }) else {
            throw NSError(domain: "LiveContainer", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "Container registration not found"])
        }
        records[index]["bookmarkData"] = renewedBookmark
        appInfo.containerInfo = records
        var saveError: NSError?
        guard appInfo.save(&saveError) else {
            throw saveError ?? NSError(domain: "LiveContainer", code: 8,
                                       userInfo: [NSLocalizedDescriptionKey: "Unable to persist renewed container bookmark"])
        }
        // Commit the in-memory bookmark only after the atomic registry write succeeds.
        storageBookMark = renewedBookmark
        bookmarkIsStale = false
    }

    public var containerURL : URL {
        if let resolvedContainerURL {
            return resolvedContainerURL
        }
        
        if isShared {
            return LCPath.lcGroupDataPath.appendingPathComponent("\(folderName)")
        } else {
            return LCPath.dataPath.appendingPathComponent("\(folderName)")
        }
    }
    private var infoDictUrl : URL {
        return containerURL.appendingPathComponent("LCContainerInfo.plist")
    }
    public var keychainGroupId : Int {
        get {
            guard hasUsableStorage else { return -1 }
            if infoDict == nil {
                infoDict = readInfoDict()
            }
            return infoDict?["keychainGroupId"] as? Int ?? -1
        }
    }
    
    public var appIdentifier : String? {
        get {
            guard hasUsableStorage else { return nil }
            if infoDict == nil {
                infoDict = readInfoDict()
            }
            return infoDict?["appIdentifier"] as? String
        }
    }
    
    init(folderName: String, name: String, isShared : Bool, isolateAppGroup: Bool = false, spoofIdentifierForVendor: Bool = false, bookmarkData: Data? = nil, resolvedContainerURL: URL? = nil) {
        self.folderName = folderName
        self.name = name
        self.isShared = isShared
        self.isolateAppGroup = isolateAppGroup
        self.spoofIdentifierForVendor = spoofIdentifierForVendor
        self.storageBookMark = bookmarkData
        self.resolvedContainerURL = resolvedContainerURL
    }
    
    convenience init(infoDict : [String : Any], isShared : Bool) {
        let bookmarkData : Data? = infoDict["bookmarkData"] as? Data
        
        self.init(folderName: infoDict["folderName"] as? String ?? "ERROR",
                  name: infoDict["name"] as? String ?? "ERROR",
                  isShared: isShared,
                  isolateAppGroup: false,
                  spoofIdentifierForVendor: false,
                  bookmarkData: bookmarkData,
                  resolvedContainerURL: nil
        )
        
        var securityScopedURL: URL?
        if let bookmarkData {
            do {
                var isStale = false
                let url = try URL(resolvingBookmarkData: bookmarkData,
                                  options: URL.BookmarkResolutionOptions(rawValue: 1 << 10),
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &isStale)
                guard url.isFileURL, !url.path.isEmpty else {
                    throw NSError(domain: "LiveContainer", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Bookmark must resolve to a file URL"])
                }
                guard url.startAccessingSecurityScopedResource() else {
                    throw NSError(domain: "LiveContainer", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Unable to access bookmark resource"])
                }
                // Keep the scoped access alive through LCContainerInfo.plist
                // loading below; release it only after all external reads finish.
                securityScopedURL = url
                var isDirectory = ObjCBool(false)
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    throw NSError(domain: "LiveContainer", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Bookmark must resolve to an accessible directory"])
                }
                self.resolvedContainerURL = url
                self.bookmarkIsStale = isStale
            } catch {
                // Do not fall back to the private container with the same name.
                // An external bookmark is the authority for this container.
                if let securityScopedURL {
                    securityScopedURL.stopAccessingSecurityScopedResource()
                }
                securityScopedURL = nil
                self.resolvedContainerURL = nil
            }
            self.bookmarkResolved = true
        }

        guard bookmarkData == nil || self.resolvedContainerURL != nil else {
            return
        }

        // Metadata reads must also go through the access helper. Do not create
        // an external directory merely because its metadata is missing.
        if let plistInfo = readInfoDict() {
            isolateAppGroup = plistInfo["isolateAppGroup"] as? Bool ?? false
            spoofIdentifierForVendor = plistInfo["spoofIdentifierForVendor"] as? Bool ?? false
            spoofedIdentifier = plistInfo["spoofedIdentifierForVendor"] as? String
            self.infoDict = plistInfo
        }
        if let securityScopedURL {
            securityScopedURL.stopAccessingSecurityScopedResource()
        }
    }
    
    func toDict() -> [String : Any] {
        var ans : [String: Any] = [
            "folderName" : folderName,
            "name" : name
        ]
        if let storageBookMark {
            ans["bookmarkData"] = storageBookMark
        }
        return ans
    }
    
    @discardableResult
    func makeLCContainerInfoPlist(appIdentifier : String, keychainGroupId : Int) -> Bool {
        guard hasUsableStorage else {
            return false
        }
        var newInfo: [String: Any] = [
            "appIdentifier" : appIdentifier,
            "folderName" : folderName,
            "name" : name,
            "keychainGroupId" : keychainGroupId,
            "isolateAppGroup" : isolateAppGroup,
            "spoofIdentifierForVendor": spoofIdentifierForVendor
        ]
        if let spoofedIdentifier {
            newInfo["spoofedIdentifierForVendor"] = spoofedIdentifier
        }
        do {
            return try withContainerAccess { url in
                let fm = FileManager.default
                let directory = url.standardizedFileURL
                var isDirectory = ObjCBool(false)
                let exists = fm.fileExists(atPath: directory.path, isDirectory: &isDirectory)
                if storageBookMark == nil {
                    if !exists {
                        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                    }
                } else {
                    guard exists, isDirectory.boolValue else { return false }
                }
                guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { return false }
                let target = directory.appendingPathComponent("LCContainerInfo.plist")
                if storageBookMark != nil && fm.fileExists(atPath: target.path) {
                    guard let existing = NSDictionary(contentsOf: target) as? [String: Any],
                          existing["appIdentifier"] as? String == appIdentifier else {
                        return false
                    }
                    if let existingFolderName = existing["folderName"] as? String,
                       existingFolderName != folderName {
                        return false
                    }
                }
                let plistData = try PropertyListSerialization.data(fromPropertyList: newInfo,
                                                                    format: .binary, options: 0)
                try plistData.write(to: target, options: [.atomic])
                infoDict = newInfo
                return true
            }
        } catch {
            return false
        }
    }
    
    func reloadInfoPlist() {
        guard hasUsableStorage else {
            infoDict = nil
            return
        }
        infoDict = readInfoDict()
    }

    func loadName() {
        guard hasUsableStorage else {
            return
        }
        reloadInfoPlist()
        guard let infoDict else {
            return
        }
        name = infoDict["name"] as? String ?? "ERROR"
        isolateAppGroup = infoDict["isolateAppGroup"] as? Bool ?? false
        spoofIdentifierForVendor = infoDict["spoofIdentifierForVendor"] as? Bool ?? false
        spoofedIdentifier = infoDict["spoofedIdentifierForVendor"] as? String
    }
    
    static func == (lhs: LCContainer, rhs: LCContainer) -> Bool {
        return lhs === rhs
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

extension LCAppInfo {
    var containers : [LCContainer] {
        get {
            if self is BuiltInSideStoreAppInfo {
                let container = LCContainer(folderName: "", name: "SideStore", isShared: false)
                container.resolvedContainerURL = LCPath.docPath.appendingPathComponent("SideStore")
                return [container]
            }
            
            var upgrade = false
            // upgrade
            if let oldDataUUID = dataUUID, containerInfo == nil {
                containerInfo = [[
                    "folderName": oldDataUUID,
                    "name": oldDataUUID
                ]]
                upgrade = true
            }
            let dictArr = containerInfo as? [[String : Any]] ?? []
            return dictArr.map{ dict in
                let ans = LCContainer(infoDict: dict, isShared: isShared)
                if upgrade {
                    ans.makeLCContainerInfoPlist(appIdentifier: bundleIdentifier()!, keychainGroupId: 0)
                }
                return ans
            }
        }
        set {
            containerInfo = newValue.map { container in
                return container.toDict()
            }
        }
    }

}
