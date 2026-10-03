import Foundation

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) {
    precondition((try? condition()) == true, message)
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let container = root.appendingPathComponent("container") // No trailing slash.
try fm.createDirectory(at: container, withIntermediateDirectories: true)
let file = root.appendingPathComponent("fake.app")
try Data("file".utf8).write(to: file)
expect(try LCFileOperations.directories(in: root).map(\.lastPathComponent) == ["container"], "Real directories must be detected without a trailing slash")
let replacement = root.appendingPathComponent("replacement")
try Data("new".utf8).write(to: replacement)
try LCFileOperations.installBundle(from: replacement, to: file, replacing: true)
expect(try Data(contentsOf: file) == Data("new".utf8), "Replacement must commit")
do {
    try LCFileOperations.installBundle(from: root.appendingPathComponent("missing"), to: file, replacing: true)
    preconditionFailure("Missing source should fail")
} catch {}
expect(try Data(contentsOf: file) == Data("new".utf8), "Failed move must restore previous content")
expect(try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".LCInstallBackup-") }.isEmpty, "Successful rollback must not leave a backup")
for value in ["", 42, "../escape", "a\\b", "a\nb"] as [Any] {
    let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": value], format: .xml, options: 0)
    try data.write(to: container.appendingPathComponent("Info.plist"))
    do { _ = try LCFileOperations.bundleIdentifier(in: container); preconditionFailure("Invalid identifier accepted") } catch {}
}
try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.App"], format: .binary, options: 0).write(to: container.appendingPathComponent("Info.plist"))
expect(try LCFileOperations.bundleIdentifier(in: container) == "com.example.App", "Valid binary plist rejected")

await MainActor.run {
    let state = DownloadRequestState()
    let old = UUID(), new = UUID()
    expect(state.begin(old), "First task rejected")
    expect(!state.begin(new), "Concurrent task allowed")
    expect(state.finish(old), "Cancellation did not finish old task")
    expect(state.begin(new), "Retry rejected")
    expect(!state.finish(old) && state.owns(new), "Late callback consumed new task")
    expect(state.finish(new) && !state.finish(new), "Repeated completion accepted")
}
expect(DownloadDelegate.progress(downloaded: 10, total: -1) == 0, "Unknown size must be finite")
expect(DownloadDelegate.progress(downloaded: 10, total: 0) == 0, "Zero total must be finite")
expect(DownloadDelegate.progress(downloaded: 20, total: 10) == 1, "Progress must be clamped")
let source = root.appendingPathComponent("download-temp")
let destination = root.appendingPathComponent("download.ipa")
try Data("ipa".utf8).write(to: source)
var completions = 0
let delegate = DownloadDelegate(destination: destination, progressCallback: { _, _, _ in }, completeCallback: { result in
    completions += 1
    if case .failure(let error) = result { preconditionFailure("Valid download failed: \(error)") }
})
let response = HTTPURLResponse(url: URL(string: "https://example.org/test.ipa")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
delegate.finish(location: source, response: response)
delegate.complete(.failure(URLError(.cancelled)))
expect(completions == 1 && fm.fileExists(atPath: destination.path), "Success followed by error must complete once")
expect(!fm.fileExists(atPath: source.path), "Temporary file was not moved synchronously")
let cancelledSource = root.appendingPathComponent("cancelled-temp")
try Data("cancelled".utf8).write(to: cancelledSource)
var cancelledCount = 0
let cancelled = DownloadDelegate(destination: root.appendingPathComponent("cancelled.ipa"), progressCallback: { _, _, _ in }, completeCallback: { _ in cancelledCount += 1 })
cancelled.complete(.failure(CancellationError()))
cancelled.finish(location: cancelledSource, response: response)
expect(cancelledCount == 1 && fm.fileExists(atPath: cancelledSource.path) && !fm.fileExists(atPath: cancelled.destination.path), "Late success after cancellation must not move files")
var failure: NSError?
let rejected = DownloadDelegate(destination: root.appendingPathComponent("rejected.ipa"), progressCallback: { _, _, _ in }, completeCallback: { result in
    if case .failure(let error) = result { failure = error as NSError }
})
rejected.finish(location: cancelledSource, response: HTTPURLResponse(url: response.url!, statusCode: 404, httpVersion: nil, headerFields: nil))
expect(failure?.domain == "LCDownloadHTTP" && failure?.code == 404 && !fm.fileExists(atPath: rejected.destination.path), "HTTP error must not be installed")
print("PASS: directory detection, bundle ID validation, replacement rollback, download isolation, cancellation, staging and HTTP rejection")
