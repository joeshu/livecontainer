//
//  SideStore.swift
//  SideStoreSupport
//
//  Created by s s on 2025/7/20.
//

import Foundation
import AppIntents
import UserNotifications

@available(iOS 17.0, *)
func performIntentRefresh(identifier: String, mangledTypeName: String, intentProgress: Progress) async throws {
    intentProgress.totalUnitCount = 100
    if UserDefaults.isSideStore() {
        try await SideStoreIntentCaller.shared.callRefreshIntent(mangledTypeName: mangledTypeName)
    } else {
        RefreshHandler.shared.progress = intentProgress
        try await RefreshHandler.shared.startRefresh(identifier: identifier, mangledName: mangledTypeName)
    }
}

@available(iOS 17.0, *)
public struct RefreshAllAppsWidgetIntent: AppIntent, ProgressReportingIntent
{
    public static var title: LocalizedStringResource { "Refresh Apps via Widget" }
    public static var isDiscoverable: Bool { false } // Don't show in Shortcuts or Spotlight.
    
    public init() {}
    
    public func perform() async throws -> some IntentResult
    {
        try await performIntentRefresh(identifier: "RefreshAllAppsWidgetIntent", mangledTypeName: "9SideStore26RefreshAllAppsWidgetIntentV", intentProgress: progress)
        return .result()
    }
}

@available(iOS 17.0, *)
public struct RefreshAllAppsIntent: AppIntent, CustomIntentMigratedAppIntent, PredictableIntent, ProgressReportingIntent, ForegroundContinuableIntent
{
    public static let intentClassName = "RefreshAllIntent"
    
    public static var title: LocalizedStringResource = "Refresh All Apps"
    public static var description = IntentDescription("Refreshes your sideloaded apps to prevent them from expiring.")
    
    public init() {}
    
    public static var parameterSummary: some ParameterSummary {
        Summary("Refresh All Apps")
    }
    
    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction {
            DisplayRepresentation(
                title: "Refresh All Apps",
                subtitle: ""
            )
        }
    }
    
    public func perform() async throws -> some IntentResult & ProvidesDialog
    {
        try await performIntentRefresh(identifier: "RefreshAllIntent", mangledTypeName: "9SideStore20RefreshAllAppsIntentV", intentProgress: progress)
        return .result(dialog: "All apps have been refreshed.")
    }
    
}


class RefreshHandler: NSObject, RefreshServer {
    private var c: CheckedContinuation<(), any Error>? = nil
    private var launchContinuation: CheckedContinuation<(), any Error>? = nil
    private let continuationLock = NSLock()
    var progress: Progress? = nil
    var listener: NSXPCListener? = nil
    var sideStorePid: Int32 = 0
    var client: RefreshClient? = nil
    var ext: NSExtension? = nil
    
    static var shared = RefreshHandler()

    private func hasRefreshContinuation() -> Bool {
        continuationLock.lock()
        defer { continuationLock.unlock() }
        return c != nil
    }

    private func setRefreshContinuation(_ continuation: CheckedContinuation<(), any Error>) {
        continuationLock.lock()
        c = continuation
        continuationLock.unlock()
    }

    private func resumeRefresh(_ result: Result<Void, any Error>) {
        continuationLock.lock()
        let continuation = c
        c = nil
        continuationLock.unlock()
        continuation?.resume(with: result)
    }

    private func setLaunchContinuation(_ continuation: CheckedContinuation<(), any Error>) {
        continuationLock.lock()
        launchContinuation = continuation
        continuationLock.unlock()
    }

    private func resumeLaunch(_ result: Result<Void, any Error>) {
        continuationLock.lock()
        let continuation = launchContinuation
        launchContinuation = nil
        continuationLock.unlock()
        continuation?.resume(with: result)
    }
    
    func startRefresh(identifier: String, mangledName: String) async throws {
        if sideStorePid <= 0 || getpgid(sideStorePid) <= 0, hasRefreshContinuation() {
            resumeRefresh(.failure(NSError(
                domain: "SideStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Built-in SideStore quit unexpectedly"]
            )))
        }
        
        if hasRefreshContinuation() {
            throw NSError(domain: "SideStore", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Another refresh task is in progress."
            ])
        }
        
        if listener == nil {
            guard let listener = startAnonymousListener(self) else {
                throw NSError(domain: "SideStore", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Unable to create the refresh XPC listener."
                ])
            }
            self.listener = listener
        }
        guard let listener = self.listener else {
            throw NSError(domain: "SideStore", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Unable to create the refresh XPC listener."
            ])
        }

        // launch SideStore if it's not running
        if (sideStorePid <= 0 || getpgid(sideStorePid) <= 0) && launchContinuation == nil {
            guard
                let lcHomeCString = getenv("LC_HOME_PATH"),
                let lcHome = String(validatingUTF8: lcHomeCString),
                !lcHome.isEmpty
            else {
                throw NSError(domain: "SideStore", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "LiveContainer home path is unavailable."
                ])
            }

            let sideStoreHomeURL = URL(fileURLWithPath: lcHome)
                .appendingPathComponent("Documents/SideStore")
            guard let bookmarkData = bookmarkForURL(sideStoreHomeURL) else {
                throw NSError(domain: "SideStore", code: 5, userInfo: [
                    NSLocalizedDescriptionKey: "Unable to create a security-scoped bookmark for SideStore."
                ])
            }

            // start LiveProcess
            let extensionItem = NSExtensionItem()
            extensionItem.userInfo = [
                "selected": "builtinSideStore",
                "bookmarks": [bookmarkData],
                "endpoint": listener.endpoint
            ]

            guard let liveProcessURL = UserDefaults.lcMainBundle().builtInPlugInsURL?.appendingPathComponent("LiveProcess.appex"),
                  let liveProcessBundle = Bundle(url: liveProcessURL)
            else {
                NSLog("Unable to locate LiveProcess bundle")
                throw NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to locate LiveProcess bundle. To use the Refresh All Apps shortcut, reinstall LiveContainer+SideStore with LiveProcess installed. If you use SideStore, choose \"Keep App Extensions (Use Main Profile)\". If you use PlumeImpactor, choose \"Only Register Main Bundle\". For other sideloaders, select keep all extensions, i.e. DO NOT Remove any extension."])
            }
            
            var ext : NSExtension?
            do {
                ext = try NSExtension(identifier: liveProcessBundle.bundleIdentifier)
            } catch {
                NSLog("Failed to start extension \(error)")
                throw NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to start extension \(error). To use the Refresh All Apps shortcut, reinstall LiveContainer+SideStore with LiveProcess installed. If you use SideStore, choose \"Keep App Extensions (Use Main Profile)\". If you use Impactor, choose \"Only Register Main Bundle\". For other sideloaders, select keep all extensions, i.e. DO NOT Remove any extension."])
            }
            guard let ext else {
                throw NSError(domain: "SideStore", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: "LiveProcess extension is unavailable."
                ])
            }
            self.ext = ext
            
            ext.setRequestInterruptionBlock { [weak self] _ in
                guard let self else { return }
                let error = NSError(domain: "SideStore", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Built-in SideStore quit unexpectedly"
                ])
                self.resumeRefresh(.failure(error))
                self.resumeLaunch(.failure(error))
                self.sideStorePid = 0
            }
            
            let uuid = await ext.beginRequest(withInputItems: [extensionItem])
            sideStorePid = ext.pid(forRequestIdentifier: uuid)
            
            try await withCheckedThrowingContinuation { continuation in
                self.setLaunchContinuation(continuation)
                DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self, weak ext] in
                    guard let self, self.launchContinuation != nil else { return }
                    self.resumeLaunch(.failure(NSError(
                        domain: "SideStore",
                        code: 7,
                        userInfo: [NSLocalizedDescriptionKey: "Built-in SideStore failed to start in reasonable time"]
                    )))
                    ext?._kill(9)
                }
            }
        }
        guard let client = self.client else {
            throw NSError(domain: "SideStore", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "The embedded SideStore XPC client is unavailable."
            ])
        }

        try await withCheckedThrowingContinuation { continuation in
            self.setRefreshContinuation(continuation)
            client.refreshAllApps(withIdentifier: identifier, mangledTypeName: mangledName)
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
                guard let self, self.hasRefreshContinuation() else { return }
                self.resumeRefresh(.failure(NSError(
                    domain: "SideStore",
                    code: 9,
                    userInfo: [NSLocalizedDescriptionKey: "SideStore refresh timed out."]
                )))
            }
        }
        
    }
    
    func updateProgress(_ value: Double) {
        progress?.completedUnitCount = Int64(value*100)
    }
    
    func finish(_ error: String?) {
        if let error {
            resumeRefresh(.failure(NSError(
                domain: "SideStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: error]
            )))
        } else {
            resumeRefresh(.success(()))
        }
    }
    
    func onConnection(_ connection: NSXPCConnection!) {
        connection.remoteObjectInterface = NSXPCInterface(with: RefreshClient.self)
        client = connection.remoteObjectProxy as? RefreshClient
    }
    
    func finishedLaunching() {
        resumeLaunch(.success(()))
    }

    func add(_ request: UNNotificationRequest) {
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("Failed to add SideStore notification: \(error)")
            }
        }
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }
    
}
