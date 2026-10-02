import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Serialize access on the caller's queue. A kernel lease spans the operation;
/// unlike a PID or a wall-clock timeout, it cannot mistake a living owner for a
/// crashed one and is released automatically when the process terminates.
final class RefreshTaskJournal {
    enum Stage: String, Codable { case launching, refreshing }
    enum Outcome: String, Codable { case success, failure, cancelled, interrupted }
    struct Attempt: Codable {
        let taskID: String
        let startedAt: Date
        var stage: Stage
        var stageStartedAt: Date
    }
    struct Completion: Codable {
        let attempt: Attempt
        let outcome: Outcome
        let finishedAt: Date
        let errorDomain: String?
        let errorCode: Int?
    }
    struct Record: Codable {
        var version = 1
        var active: Attempt?
        var lastCompletion: Completion?
    }
    enum JournalError: Error { case busy, unsupportedVersion, invalidRecord, wrongTask, noLease }

    let directory: URL
    private var lease: Int32 = -1
    private var record = Record()
    private let fileManager = FileManager.default
    var fileURL: URL { directory.appendingPathComponent("refresh.json") }

    init(directory: URL) { self.directory = directory }
    deinit { release() }

    /// Holding this lock also protects a live operation against startup recovery
    /// in another app/intent process. Never unlink the lock file: that would allow
    /// two different lock-file inodes to protect the same journal.
    private func acquire() throws -> Bool {
        guard lease < 0 else { throw JournalError.noLease }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let descriptor = open(directory.appendingPathComponent("refresh.lock").path,
                              O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw posixError() }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN { return false }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        lease = descriptor
        return true
    }

    private func release() {
        if lease >= 0 {
            flock(lease, LOCK_UN)
            close(lease)
            lease = -1
        }
    }

    private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

    private func read() throws -> Record {
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return Record()
        }
        struct Header: Decodable { let version: Int }
        guard try JSONDecoder().decode(Header.self, from: data).version == 1 else {
            throw JournalError.unsupportedVersion
        }
        let value = try JSONDecoder().decode(Record.self, from: data)
        let attempts = [value.active, value.lastCompletion?.attempt].compactMap { $0 }
        guard attempts.allSatisfy({ !$0.taskID.isEmpty && $0.startedAt.timeIntervalSince1970.isFinite && $0.stageStartedAt.timeIntervalSince1970.isFinite }),
              value.lastCompletion?.finishedAt.timeIntervalSince1970.isFinite != false else { throw JournalError.invalidRecord }
        return value
    }

    /// Decode failures may be quarantined under the lease. Unknown future
    /// versions and I/O errors fail closed rather than discarding newer state.
    private func readForRecovery() throws -> Record {
        do { return try read() }
        catch is DecodingError { return try quarantine() }
        catch JournalError.invalidRecord { return try quarantine() }
    }

    private func quarantine() throws -> Record {
        let target = directory.appendingPathComponent("refresh.corrupt-\(UUID().uuidString).json")
        try fileManager.moveItem(at: fileURL, to: target)
        return Record()
    }

    private func write(_ value: Record) throws {
        let data = try JSONEncoder().encode(value)
        #if os(iOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: fileURL, options: .atomic)
        #endif
        record = value
    }

    private func recovered(_ value: Record, now: Date) -> Record {
        guard let attempt = value.active else { return value }
        var next = value
        next.active = nil
        next.lastCompletion = Completion(attempt: attempt, outcome: .interrupted, finishedAt: now,
                                         errorDomain: nil, errorCode: nil)
        return next
    }

    /// A busy lease means another process is alive. Read its atomic snapshot
    /// without modifying it, regardless of the age of its timestamps.
    func recoverAndRead(now: Date = Date()) throws -> Record {
        guard try acquire() else { return try read() }
        defer { release() }
        let previous = try readForRecovery()
        let next = recovered(previous, now: now)
        if previous.active != nil { try write(next) }
        return next
    }

    func begin(taskID: String, now: Date = Date()) throws {
        guard !taskID.isEmpty else { throw JournalError.invalidRecord }
        guard try acquire() else { throw JournalError.busy }
        do {
            let previous = try readForRecovery()
            var next = recovered(previous, now: now)
            next.active = Attempt(taskID: taskID, startedAt: now, stage: .launching, stageStartedAt: now)
            try write(next)
        } catch {
            release()
            throw error
        }
    }

    func markRefreshing(taskID: String, now: Date = Date()) throws {
        guard lease >= 0 else { throw JournalError.noLease }
        guard var attempt = record.active, attempt.taskID == taskID else { throw JournalError.wrongTask }
        attempt.stage = .refreshing
        attempt.stageStartedAt = now
        var next = record
        next.active = attempt
        try write(next)
    }

    func finish(taskID: String, outcome: Outcome, error: NSError? = nil, now: Date = Date()) throws {
        guard lease >= 0 else { throw JournalError.noLease }
        guard let attempt = record.active, attempt.taskID == taskID else { throw JournalError.wrongTask }
        // Keep the lease even on an ID mismatch; a late callback cannot release
        // the lease of the current attempt. I/O failure releases it so recovery
        // can report an unconfirmed result rather than permanently blocking.
        defer { release() }
        var next = record
        next.active = nil
        next.lastCompletion = Completion(attempt: attempt, outcome: outcome, finishedAt: now,
                                         errorDomain: error?.domain, errorCode: error?.code)
        try write(next)
    }
}
