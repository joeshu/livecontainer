import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

// Startup signals may arrive in any order, including before beginRequest returns.
let orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
for order in orders {
    let state = RefreshTaskState()
    require(state.begin(taskID: "A"), "First operation should reserve the bridge")
    require(!state.begin(taskID: "B"), "A second operation must not overwrite a launching task")
    for (index, signal) in order.enumerated() {
        switch signal {
        case 0: state.markConnected(generation: state.generation)
        case 1: state.markLaunched(generation: state.generation)
        default: state.markLaunchReturned(generation: state.generation)
        }
        require(state.isReady == (index == 2), "All three startup signals are required")
    }
    require(state.beginRefreshIfReady() == "A", "Early readiness must be latched")
    require(state.beginRefreshIfReady() == nil, "Do not dispatch refresh twice")
    require(!state.matches(taskID: "A", phase: .launching), "Old launch timeout must not end a refresh")
    require(state.finish(taskID: "A"), "A should complete")
    require(!state.finish(taskID: "A"), "Duplicate callback must be ignored")
    require(state.begin(taskID: "B"), "B should start after A completes")
    require(state.beginRefreshIfReady() == "B", "A ready process should be reused")
    require(!state.matches(taskID: "A", phase: .refreshing), "A's old timeout must not end B")
    require(!state.finish(taskID: "A"), "A's late completion must not end B")
    let oldGeneration = state.generation
    require(state.finish(taskID: "B"), "Failure should release B")
    state.resetProcess()
    require(state.begin(taskID: "C"), "Recovery should accept a new operation")
    state.markConnected(generation: oldGeneration)
    state.markLaunched(generation: oldGeneration)
    state.markLaunchReturned(generation: oldGeneration)
    require(!state.isReady, "Callbacks from the disconnected process must be ignored")
}

let cancellation = RefreshCancellation()
cancellation.cancel()
require(cancellation.isCancelled, "Cancellation before registration must be preserved")

// Exercise the actual once-only completion gate with concurrent callbacks.
let gate = RefreshCompletionGate()
let lock = NSLock()
var winners = 0
DispatchQueue.concurrentPerform(iterations: 100) { _ in
    if gate.claim() {
        lock.lock()
        winners += 1
        lock.unlock()
    }
}
require(winners == 1, "Exactly one callback may resume the continuation")
print("PASS: startup permutations, task isolation, reconnect, cancellation, concurrent completion")
