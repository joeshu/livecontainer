import Foundation

/// Only the current request may update the UI or consume its continuation.
@MainActor
final class DownloadRequestState {
    private(set) var taskID: UUID?
    func begin(_ id: UUID) -> Bool {
        guard taskID == nil else { return false }
        taskID = id
        return true
    }
    func owns(_ id: UUID) -> Bool { taskID == id }
    func finish(_ id: UUID) -> Bool {
        guard owns(id) else { return false }
        taskID = nil
        return true
    }
}

/// URLSession deletes its temporary file after the delegate returns. Move it
/// synchronously, before handing the result to an asynchronous UI callback.
final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let destination: URL
    let progressCallback: (Float, Int64, Int64) -> Void
    let completeCallback: (Result<Void, Error>) -> Void
    private let lock = NSLock()
    private var completed = false

    init(destination: URL, progressCallback: @escaping (Float, Int64, Int64) -> Void,
         completeCallback: @escaping (Result<Void, Error>) -> Void) {
        self.destination = destination
        self.progressCallback = progressCallback
        self.completeCallback = completeCallback
    }

    private func claimCompletion() -> Bool {
        lock.lock()
        let shouldComplete = !completed
        completed = true
        lock.unlock()
        return shouldComplete
    }

    func complete(_ result: Result<Void, Error>) {
        if claimCompletion() { completeCallback(result) }
    }

    static func progress(downloaded: Int64, total: Int64) -> Float {
        guard total > 0 else { return 0 }
        return Float(min(1, max(0, Double(downloaded) / Double(total))))
    }

    func finish(location: URL, response: URLResponse?) {
        guard claimCompletion() else { return }
        do {
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard (200...299).contains(response.statusCode) else {
                throw NSError(domain: "LCDownloadHTTP", code: response.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: HTTPURLResponse.localizedString(forStatusCode: response.statusCode)])
            }
            try FileManager.default.moveItem(at: location, to: destination)
            completeCallback(.success(()))
        } catch {
            completeCallback(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progressCallback(Self.progress(downloaded: totalBytesWritten, total: totalBytesExpectedToWrite),
                         max(0, totalBytesWritten), max(0, totalBytesExpectedToWrite))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        finish(location: location, response: downloadTask.response)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { complete(.failure(error)) }
        // Break URLSession's retention of the delegate after every request.
        session.finishTasksAndInvalidate()
    }
}
