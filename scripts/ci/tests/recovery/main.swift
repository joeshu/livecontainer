import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

func require(_ condition: Bool, _ message: String) {
    precondition(condition, message)
}

if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "worker" {
    let journal = RefreshTaskJournal(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
    let worker = try journal.claimWorker(taskID: "killed-task")
    FileHandle.standardOutput.write(Data("READY\n".utf8))
    while true {
        sleep(1)
        // Keep the lease alive across the simulated worker's operation.
        withExtendedLifetime(worker) {}
    }
}

if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "hold" {
    let journal = RefreshTaskJournal(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
    try journal.begin(taskID: "killed-task")
    if CommandLine.arguments[3] == "refreshing" { try journal.markRefreshing(taskID: "killed-task") }
    FileHandle.standardOutput.write(Data("READY\n".utf8))
    while true { sleep(1) }
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("refresh-journal-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
// Production factories must not confuse the worker's extension HOME with the
// host's journal. A missing explicitly scoped path fails closed.
let originalHome = ProcessInfo.processInfo.environment["LC_HOME_PATH"]
let originalJournalPath = ProcessInfo.processInfo.environment["LC_REFRESH_JOURNAL_PATH"]
defer {
    if let originalHome { setenv("LC_HOME_PATH", originalHome, 1) } else { unsetenv("LC_HOME_PATH") }
    if let originalJournalPath { setenv("LC_REFRESH_JOURNAL_PATH", originalJournalPath, 1) } else { unsetenv("LC_REFRESH_JOURNAL_PATH") }
}
setenv("LC_HOME_PATH", root.appendingPathComponent("host").path, 1)
let hostJournal = try RefreshRecovery.makeJournal()
setenv("LC_REFRESH_JOURNAL_PATH", hostJournal.directory.path, 1)
setenv("LC_HOME_PATH", root.appendingPathComponent("extension").path, 1)
require(try RefreshRecovery.makeWorkerJournal().directory.path == hostJournal.directory.path,
        "Worker must use the explicitly scoped host journal despite its different home")
unsetenv("LC_REFRESH_JOURNAL_PATH")
do {
    _ = try RefreshRecovery.makeWorkerJournal()
    fatalError("Missing worker access must not silently choose a private extension journal")
} catch {}

let start = Date(timeIntervalSince1970: 1_700_000_000)
let owner = RefreshTaskJournal(directory: root.appendingPathComponent("normal"))
try owner.begin(taskID: "A", now: start)
let observer = RefreshTaskJournal(directory: owner.directory)
let live = try observer.recoverAndRead(now: start.addingTimeInterval(100_000))
require(live.active?.taskID == "A", "Startup must not recover an old but living owner")
require(live.active?.stage == .launching, "Launching stage must be persisted")
do {
    try observer.begin(taskID: "B")
    fatalError("A concurrent operation must not acquire the lease")
} catch RefreshTaskJournal.JournalError.busy {}
try owner.markRefreshing(taskID: "A", now: start.addingTimeInterval(10))
do {
    try owner.finish(taskID: "stale", outcome: .success)
    fatalError("A stale callback must not release the current lease")
} catch RefreshTaskJournal.JournalError.wrongTask {}
do {
    try observer.begin(taskID: "B")
    fatalError("Mismatched completion released the live lease")
} catch RefreshTaskJournal.JournalError.busy {}
try owner.finish(taskID: "A", outcome: .success, now: start.addingTimeInterval(20))
let completed = try observer.recoverAndRead()
require(completed.active == nil && completed.lastCompletion?.outcome == .success, "Successful task must clear active state")
require(completed.lastCompletion?.attempt.stage == .refreshing, "Result must retain its last stage")
require(completed.lastCompletion?.attempt.startedAt == start, "Start time must survive reload")
try observer.begin(taskID: "B")
try observer.finish(taskID: "B", outcome: .cancelled)
require(try owner.recoverAndRead().lastCompletion?.outcome == .cancelled, "Cancellation must be persisted")
try owner.begin(taskID: "C")
try owner.finish(taskID: "C", outcome: .failure, error: NSError(domain: "test", code: 42))
let failed = try observer.recoverAndRead()
require(failed.lastCompletion?.errorDomain == "test" && failed.lastCompletion?.errorCode == 42, "Failure identity must survive restart")
require(!String(data: try Data(contentsOf: owner.fileURL), encoding: .utf8)!.contains("localizedDescription"), "Do not persist account-bearing error descriptions")

// Kill a real owner process in each phase. This exercises kernel lock release,
// not merely an in-memory reset or an orderly deinitializer.
for stage in ["launching", "refreshing"] {
    let directory = root.appendingPathComponent(stage)
    let child = Process()
    let output = Pipe()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["hold", directory.path, stage]
    child.standardOutput = output
    try child.run()
    let ready = try output.fileHandleForReading.read(upToCount: 6)
    require(ready == Data("READY\n".utf8), "Child must write state before termination")
    let journal = RefreshTaskJournal(directory: directory)
    require(try journal.recoverAndRead().active?.taskID == "killed-task", "A second process must not clear a live owner")
    kill(child.processIdentifier, SIGKILL)
    child.waitUntilExit()
    let recovered = try journal.recoverAndRead()
    require(recovered.active == nil && recovered.lastCompletion?.outcome == .interrupted, "Killed owner must become unconfirmed, not remain running")
    require(recovered.lastCompletion?.attempt.stage.rawValue == stage, "Recovery must retain the interrupted phase")
    let again = try journal.recoverAndRead()
    require(again.lastCompletion?.finishedAt == recovered.lastCompletion?.finishedAt, "Recovery must be idempotent")
    try journal.begin(taskID: "retry")
    try journal.markRefreshing(taskID: "retry")
    try journal.finish(taskID: "retry", outcome: .success)
}

// The coordinator can die while the actual extension remains alive. A second
// process must not clear its task or overlap its work until the worker exits.
let workerDirectory = root.appendingPathComponent("orphan-worker")
let coordinator = Process()
let coordinatorOutput = Pipe()
coordinator.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
coordinator.arguments = ["hold", workerDirectory.path, "refreshing"]
coordinator.standardOutput = coordinatorOutput
try coordinator.run()
require(try coordinatorOutput.fileHandleForReading.read(upToCount: 6) == Data("READY\n".utf8), "Coordinator must be ready")
let worker = Process()
let workerOutput = Pipe()
worker.executableURL = coordinator.executableURL
worker.arguments = ["worker", workerDirectory.path]
worker.standardOutput = workerOutput
try worker.run()
require(try workerOutput.fileHandleForReading.read(upToCount: 6) == Data("READY\n".utf8), "Worker must hold its independent lease")
kill(coordinator.processIdentifier, SIGKILL)
coordinator.waitUntilExit()
let workerObserver = RefreshTaskJournal(directory: workerDirectory)
require(try workerObserver.recoverAndRead().active?.taskID == "killed-task", "A live extension must remain protected after coordinator death")
do {
    try workerObserver.begin(taskID: "overlap")
    fatalError("Do not overlap a living orphan worker")
} catch RefreshTaskJournal.JournalError.busy {}
kill(worker.processIdentifier, SIGKILL)
worker.waitUntilExit()
require(try workerObserver.recoverAndRead().lastCompletion?.outcome == .interrupted, "Recover only after both owners have exited")
try workerObserver.begin(taskID: "new-task")
try workerObserver.markRefreshing(taskID: "new-task")
do {
    _ = try workerObserver.claimWorker(taskID: "killed-task")
    fatalError("A late RPC must not invoke an old operation")
} catch RefreshTaskJournal.JournalError.wrongTask {}
let newWorker = try workerObserver.claimWorker(taskID: "new-task")
newWorker.release()
try workerObserver.finish(taskID: "new-task", outcome: .success)

// A damaged record is quarantined, but unknown newer schemas are retained.
let damaged = RefreshTaskJournal(directory: root.appendingPathComponent("damaged"))
_ = try damaged.recoverAndRead()
try Data("{truncated".utf8).write(to: damaged.fileURL)
require(try damaged.recoverAndRead().active == nil, "Corrupt state must not prevent recovery")
let quarantines = try FileManager.default.contentsOfDirectory(atPath: damaged.directory.path)
require(quarantines.contains(where: { $0.hasPrefix("refresh.corrupt-") }), "Preserve corrupt state for diagnosis")
try damaged.begin(taskID: "after-corruption")
try damaged.finish(taskID: "after-corruption", outcome: .success)
let newer = Data("{\"version\":2,\"active\":{\"future\":true}}".utf8)
try newer.write(to: damaged.fileURL)
do {
    _ = try damaged.recoverAndRead()
    fatalError("Unknown versions must fail closed")
} catch RefreshTaskJournal.JournalError.unsupportedVersion {}
require(try Data(contentsOf: damaged.fileURL) == newer, "Do not overwrite future schemas")

// Exercise an actual atomic completion-write failure after an operation starts.
let unwritable = RefreshTaskJournal(directory: root.appendingPathComponent("unwritable"))
try unwritable.begin(taskID: "write-failure")
let interruptedData = try Data(contentsOf: unwritable.fileURL)
try FileManager.default.removeItem(at: unwritable.fileURL)
try FileManager.default.createDirectory(at: unwritable.fileURL, withIntermediateDirectories: false)
try Data("blocker".utf8).write(to: unwritable.fileURL.appendingPathComponent("blocker"))
do {
    try unwritable.finish(taskID: "write-failure", outcome: .success)
    fatalError("Atomic completion must not overwrite a directory")
} catch {}
try FileManager.default.removeItem(at: unwritable.fileURL)
try interruptedData.write(to: unwritable.fileURL)
let retry = RefreshTaskJournal(directory: unwritable.directory)
require(try retry.recoverAndRead().lastCompletion?.outcome == .interrupted, "Failed completion persistence must release its lease and retain an unconfirmed result")
try retry.begin(taskID: "after-write-failure")
try retry.finish(taskID: "after-write-failure", outcome: .success)
print("PASS: real process death in both phases, orphan-worker isolation, stale RPC rejection, outcomes, corruption, schema protection and I/O recovery")
