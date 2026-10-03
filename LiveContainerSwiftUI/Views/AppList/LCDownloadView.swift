//
//  LCDownloadView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2025/1/22.
//

import SwiftUI

@MainActor
public final class DownloadHelper : ObservableObject {
    @Published var downloadProgress : Float = 0.0
    @Published var downloadedSize : Int64 = 0
    @Published var totalSize : Int64 = 0
    @Published var isDownloading = false
    @Published var cancelled = false
    private var downloadTask: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var delegate: DownloadDelegate?
    private let requestState = DownloadRequestState()

    @MainActor
    func download(url: URL, to: URL) async throws {
        let id = UUID()
        try Task.checkCancellation()
        guard requestState.begin(id) else {
            throw URLError(.backgroundSessionInUseByAnotherProcess)
        }
        cancelled = false
        downloadProgress = 0
        downloadedSize = 0
        totalSize = 0
        isDownloading = true

        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                continuation = c
                if Task.isCancelled {
                    cancel(requestID: id, throwsCancellation: true)
                    return
                }
                let delegate = DownloadDelegate(destination: to, progressCallback: { progress, downloaded, total in
                    Task { @MainActor in
                        guard self.requestState.owns(id) else { return }
                        self.downloadProgress = progress
                        self.downloadedSize = downloaded
                        self.totalSize = total
                    }
                }, completeCallback: { result in
                    Task { @MainActor in self.finish(requestID: id, result: result) }
                })
                self.delegate = delegate
                let config = URLSessionConfiguration.background(withIdentifier: "com.livecontainer.download.\(id.uuidString)")
                let session = URLSession(configuration: config, delegate: delegate, delegateQueue: .main)
                self.session = session
                downloadTask = session.downloadTask(with: url)
                downloadTask?.resume()
            }
        }, onCancel: {
            Task { @MainActor in self.cancel(requestID: id, throwsCancellation: true) }
        })
    }

    @MainActor
    private func finish(requestID: UUID, result: Result<Void, Error>) {
        guard requestState.finish(requestID) else { return }
        let pending = continuation
        continuation = nil
        downloadTask = nil
        delegate = nil
        session?.finishTasksAndInvalidate()
        session = nil
        isDownloading = false
        pending?.resume(with: result)
    }

    @MainActor
    private func cancel(requestID: UUID, throwsCancellation: Bool) {
        guard requestState.owns(requestID) else { return }
        cancelled = true
        delegate?.complete(.failure(CancellationError()))
        downloadTask?.cancel()
        session?.invalidateAndCancel()
        finish(requestID: requestID, result: throwsCancellation ? .failure(CancellationError()) : .success(()))
    }

    @MainActor
    func cancel() {
        guard let id = requestState.taskID else { return }
        cancel(requestID: id, throwsCancellation: false)
    }
}

struct DownloadAlert : View {
    @StateObject var helper : DownloadHelper
    var body: some View {
        
        Color.black.opacity(0.2) // Semi-transparent grey background
            .edgesIgnoringSafeArea(.all) // Covers entire screen
        
        VStack {
            Text("lc.download.downloading".loc)
                .font(.headline)
                .padding(.top)
            
            if helper.totalSize > 0 {
                ProgressView(value: helper.downloadProgress, total: 1)
                    .padding()
            } else {
                ProgressView()
                    .padding()
            }
            
            Text(helper.totalSize > 0 ? "\(formatBytes(helper.downloadedSize)) / \(formatBytes(helper.totalSize))" : formatBytes(helper.downloadedSize))
                .font(.subheadline)
                .padding(.bottom)
            
            Button(action: cancelDownload) {
                Text("lc.common.cancel".loc)
                    .foregroundColor(.red)
                    .padding(.bottom)
            }
        }
        .frame(width: 300)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
        .shadow(radius: 10)
        .padding()
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB] // Allow KB, MB, and GB
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    func cancelDownload() {
        helper.cancel()
    }
}

public struct DownloadAlertModifier: ViewModifier {
    @ObservedObject var helper : DownloadHelper
    @State var show = false
    
    public func body(content: Content) -> some View {

        ZStack {
            content
            if show {
                DownloadAlert(helper: helper)
                
            }
            
        }
        .onChange(of: helper.isDownloading) { newVal in
            withAnimation(.easeInOut(duration: 0.1)) {
                show = newVal
            }
        }
    }
}

extension View {
    public func downloadAlert(helper: DownloadHelper) -> some View {
        self.modifier(DownloadAlertModifier(helper: helper))
    }
}
