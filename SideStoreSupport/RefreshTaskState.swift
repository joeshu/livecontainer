import Foundation

// Foundation-only lifecycle used by the bridge and executable regression tests.
// Callers serialize access on the main queue; no asynchronous work occurs here.
final class RefreshTaskState {
    enum Phase { case idle, launching, refreshing }
    private(set) var taskID: String?
    private(set) var phase: Phase = .idle
    private(set) var generation = UUID().uuidString
    private var connected = false
    private var launched = false
    private var launchReturned = false

    var isReady: Bool { connected && launched && launchReturned }

    func begin(taskID: String) -> Bool {
        guard self.taskID == nil else { return false }
        self.taskID = taskID
        phase = .launching
        return true
    }

    func markConnected(generation: String) {
        if self.generation == generation { connected = true }
    }

    func markLaunched(generation: String) {
        if self.generation == generation { launched = true }
    }

    func markLaunchReturned(generation: String) {
        if self.generation == generation { launchReturned = true }
    }

    func beginRefreshIfReady() -> String? {
        guard phase == .launching, isReady else { return nil }
        phase = .refreshing
        return taskID
    }

    func matches(taskID: String, phase: Phase) -> Bool {
        self.taskID == taskID && self.phase == phase
    }

    func finish(taskID: String) -> Bool {
        guard self.taskID == taskID else { return false }
        self.taskID = nil
        phase = .idle
        return true
    }

    func resetProcess() {
        generation = UUID().uuidString
        connected = false
        launched = false
        launchReturned = false
    }
}

// Cancellation can arrive on any executor, including before task registration.
final class RefreshCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

final class RefreshCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        return true
    }
}
