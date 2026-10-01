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
        try await RefreshHandler.shared.startRefresh(identifier: identifier, mangledName: mangledTypeName, progress: intentProgress)
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


// All lifecycle state is confined to the main queue. XPC and extension callbacks
// carry a process generation; refresh callbacks additionally carry a task ID.
class RefreshHandler: NSObject {
    static let shared = RefreshHandler()
    private let state = RefreshTaskState()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var progress: Progress?
    private var timeout: DispatchWorkItem?
    private var listener: NSXPCListener?
    private var connection: NSXPCConnection?
    private var client: RefreshClient?
    private var ext: NSExtension?
    private var sideStorePid: Int32 = 0

    private func failure(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "SideStore", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func startRefresh(identifier: String, mangledName: String, progress: Progress) async throws {
        let taskID = UUID().uuidString
        let cancellation = RefreshCancellation()
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                DispatchQueue.main.async {
                    if cancellation.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    self.begin(taskID: taskID, identifier: identifier, mangledName: mangledName,
                               progress: progress, continuation: continuation)
                }
            }
        }, onCancel: {
            cancellation.cancel()
            DispatchQueue.main.async {
                self.complete(taskID: taskID, result: .failure(CancellationError()), resetProcess: true)
            }
        })
    }

    private func begin(taskID: String, identifier: String, mangledName: String,
                       progress: Progress, continuation: CheckedContinuation<Void, any Error>) {
        // Reserve the entire operation before starting an extension or awaiting XPC.
        guard state.taskID == nil else {
            continuation.resume(throwing: failure(2, "Another refresh task is in progress."))
            return
        }
        if sideStorePid <= 0 || getpgid(sideStorePid) < 0 {
            tearDownProcess()
        }
        guard state.begin(taskID: taskID) else { return }
        self.continuation = continuation
        self.progress = progress
        self.identifier = identifier
        self.mangledName = mangledName
        armTimeout(taskID: taskID, phase: .launching)

        if state.isReady {
            sendRefreshIfReady()
            return
        }
        do {
            try launchProcess()
        } catch {
            complete(taskID: taskID, result: .failure(error), resetProcess: true)
        }
    }

    private var identifier = ""
    private var mangledName = ""

    private func launchProcess() throws {
        let generation = state.generation
        let reporter = RefreshConnectionReporter(handler: self, generation: generation)
        guard let listener = startAnonymousListener(reporter) else {
            throw failure(3, "Unable to create the refresh XPC listener.")
        }
        self.listener = listener
        guard let homePointer = getenv("LC_HOME_PATH"),
              let home = String(validatingUTF8: homePointer), !home.isEmpty else {
            throw failure(4, "LiveContainer home path is unavailable.")
        }
        let homeURL = URL(fileURLWithPath: home).appendingPathComponent("Documents/SideStore")
        guard let bookmark = bookmarkForURL(homeURL) else {
            throw failure(5, "Unable to create a security-scoped bookmark for SideStore.")
        }
        guard let extensionURL = UserDefaults.lcMainBundle().builtInPlugInsURL?.appendingPathComponent("LiveProcess.appex"),
              let bundle = Bundle(url: extensionURL),
              let bundleIdentifier = bundle.bundleIdentifier else {
            throw failure(6, "Unable to locate LiveProcess bundle. Reinstall LiveContainer+SideStore and keep app extensions (Use Main Profile).")
        }
        let ext = try NSExtension(identifier: bundleIdentifier)
        self.ext = ext
        ext.setRequestInterruptionBlock { [weak self] _ in
            DispatchQueue.main.async {
                self?.processFailed(generation: generation, message: "Built-in SideStore quit unexpectedly")
            }
        }
        let item = NSExtensionItem()
        item.userInfo = ["selected": "builtinSideStore", "bookmarks": [bookmark], "endpoint": listener.endpoint]
        // The operation is already registered. Readiness is latched even if the
        // didFinishLaunching signal arrives before beginRequest returns.
        Task {
            let request = await ext.beginRequest(withInputItems: [item])
            DispatchQueue.main.async {
                guard self.state.generation == generation else {
                    ext._kill(9)
                    return
                }
                self.sideStorePid = ext.pid(forRequestIdentifier: request)
                guard self.sideStorePid > 0 else {
                    self.processFailed(generation: generation, message: "Built-in SideStore failed to start.")
                    return
                }
                self.state.markLaunchReturned(generation: generation)
                self.sendRefreshIfReady()
            }
        }
    }

    fileprivate func connected(_ connection: NSXPCConnection, generation: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard generation == state.generation, self.connection == nil else {
            connection.invalidate()
            return
        }
        self.connection = connection
        connection.remoteObjectInterface = NSXPCInterface(with: RefreshClient.self)
        connection.interruptionHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.processFailed(generation: generation, message: "SideStore refresh XPC connection was interrupted.")
            }
        }
        connection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.processFailed(generation: generation, message: "SideStore refresh XPC connection was invalidated.")
            }
        }
        client = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            DispatchQueue.main.async {
                self?.processFailed(generation: generation, message: error.localizedDescription)
            }
        } as? RefreshClient
        guard client != nil else {
            processFailed(generation: generation, message: "The embedded SideStore XPC client is unavailable.")
            return
        }
        state.markConnected(generation: generation)
        sendRefreshIfReady()
    }

    fileprivate func launched(generation: String) {
        state.markLaunched(generation: generation)
        sendRefreshIfReady()
    }

    private func sendRefreshIfReady() {
        guard let client, let taskID = state.beginRefreshIfReady() else { return }
        armTimeout(taskID: taskID, phase: .refreshing)
        client.refreshAllApps(withIdentifier: identifier, mangledTypeName: mangledName, taskID: taskID)
    }

    private func armTimeout(taskID: String, phase: RefreshTaskState.Phase) {
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state.matches(taskID: taskID, phase: phase) else { return }
            let message = phase == .launching ? "Built-in SideStore failed to start in reasonable time" : "SideStore refresh timed out."
            self.complete(taskID: taskID, result: .failure(self.failure(9, message)), resetProcess: true)
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: work)
    }

    fileprivate func updateProgress(_ value: Double, taskID: String, generation: String) {
        guard generation == state.generation, state.matches(taskID: taskID, phase: .refreshing), value.isFinite else { return }
        progress?.completedUnitCount = Int64(min(1, max(0, value)) * 100)
    }

    fileprivate func finish(_ error: String?, taskID: String, generation: String) {
        guard generation == state.generation, state.matches(taskID: taskID, phase: .refreshing) else { return }
        let result: Result<Void, any Error> = error.map { .failure(failure(1, $0)) } ?? .success(())
        complete(taskID: taskID, result: result, resetProcess: error != nil)
    }

    private func processFailed(generation: String, message: String) {
        guard generation == state.generation else { return }
        if let taskID = state.taskID {
            complete(taskID: taskID, result: .failure(failure(8, message)), resetProcess: true)
        } else {
            tearDownProcess()
        }
    }

    private func complete(taskID: String, result: Result<Void, any Error>, resetProcess: Bool) {
        guard state.finish(taskID: taskID) else { return }
        timeout?.cancel()
        timeout = nil
        let continuation = self.continuation
        self.continuation = nil
        progress = nil
        if resetProcess { tearDownProcess() }
        continuation?.resume(with: result)
    }

    private func tearDownProcess() {
        // Invalidate the generation before killing the old extension. Late
        // interruption, readiness and completion callbacks cannot affect a retry.
        state.resetProcess()
        connection?.interruptionHandler = nil
        connection?.invalidationHandler = nil
        connection?.invalidate()
        connection = nil
        client = nil
        listener?.invalidate()
        listener = nil
        ext?._kill(9)
        ext = nil
        sideStorePid = 0
    }
}

private final class RefreshConnectionReporter: NSObject, RefreshServer {
    private weak var handler: RefreshHandler?
    private let generation: String

    init(handler: RefreshHandler, generation: String) {
        self.handler = handler
        self.generation = generation
    }

    func onConnection(_ connection: NSXPCConnection!) {
        guard let connection else { return }
        DispatchQueue.main.async { self.handler?.connected(connection, generation: self.generation) }
    }

    func finishedLaunching() {
        DispatchQueue.main.async { self.handler?.launched(generation: self.generation) }
    }

    func updateProgress(_ value: Double, taskID: String) {
        DispatchQueue.main.async { self.handler?.updateProgress(value, taskID: taskID, generation: self.generation) }
    }

    func finish(_ error: String?, taskID: String) {
        DispatchQueue.main.async { self.handler?.finish(error, taskID: taskID, generation: self.generation) }
    }

    func add(_ request: UNNotificationRequest, reply: @escaping (String?) -> Void) {
        UNUserNotificationCenter.current().add(request) { error in reply(error?.localizedDescription) }
    }

    func notificationAuthorizationStatus(_ reply: @escaping (Int) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            reply(settings.authorizationStatus.rawValue)
        }
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}
