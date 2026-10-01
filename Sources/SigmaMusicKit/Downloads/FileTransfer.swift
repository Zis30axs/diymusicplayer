import Foundation

/// Fetches a file onto the disk; the seam between the download queue and the network, so the queue can be
/// tested without one.
public protocol FileTransfer: Sendable {
    /// Saves `url` at `destination`, reporting how far along it is (0...1). Throws `CancellationError` when
    /// the calling task is cancelled.
    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws

    /// The destination paths of the downloads the system is still working on: after the app was relaunched
    /// they are the ones that were started by an earlier run.
    func activeDestinations() async -> Set<String>

    /// Called when a download finishes (or fails) that nobody in this run of the app was waiting for.
    func onUnattendedFinish(_ handler: @escaping @Sendable () -> Void)
}

/// Downloads through a *background* `URLSession`: the system keeps transferring while the app is suspended
/// (a watch suspends it a few seconds after the wrist goes down) and wakes the app when the files are in.
/// The delegate moves each file to its place the moment it arrives, so a finished download is never lost
/// even when the app was not running to take delivery.
public final class URLSessionFileTransfer: NSObject, FileTransfer, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct Waiter {
        let progress: @Sendable (Double) -> Void
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var waiters: [Int: Waiter] = [:]
    private var outcomes: [Int: Result<Void, any Error>] = [:]
    private var unattended: (@Sendable () -> Void)?
    private var eventsDelivered = false
    private var session: URLSession!

    /// - Parameter background: `false` makes an ordinary session (for the command-line tool, which has no
    ///   app for the system to wake).
    public init(identifier: String, background: Bool = true) {
        super.init()
        let configuration: URLSessionConfiguration
        if background {
            configuration = URLSessionConfiguration.background(withIdentifier: identifier)
            configuration.sessionSendsLaunchEvents = true
            configuration.isDiscretionary = false
        } else {
            configuration = URLSessionConfiguration.ephemeral
        }
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    public func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let task = session.downloadTask(with: url)
        task.taskDescription = destination.path
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.withLock { waiters[task.taskIdentifier] = Waiter(progress: progress, continuation: continuation) }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    public func activeDestinations() async -> Set<String> {
        let tasks = await session.allTasks
        return Set(tasks.compactMap { task in
            task.state == .running || task.state == .suspended ? task.taskDescription : nil
        })
    }

    public func onUnattendedFinish(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { unattended = handler }
    }

    /// For the app's background-task handler: returns once the system has handed over everything it queued
    /// for this session while the app was not running (or after `timeout`).
    public func waitForBackgroundEvents(timeout: Duration = .seconds(25)) async {
        let deadline = ContinuousClock.now + timeout
        while !lock.withLock({ eventsDelivered }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
        lock.withLock { eventsDelivered = false }
    }

    // MARK: URLSessionDownloadDelegate

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let waiter = lock.withLock { waiters[downloadTask.taskIdentifier] }
        waiter?.progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let outcome: Result<Void, any Error>
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode >= 400 {
            outcome = .failure(MusicServiceError.http(status: http.statusCode, path: downloadTask.originalRequest?.url?.path ?? ""))
        } else if let path = downloadTask.taskDescription {
            // The temporary file is deleted when this returns: move it now.
            let destination = URL(fileURLWithPath: path)
            let files = FileManager.default
            do {
                try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
                try files.moveItem(at: location, to: destination)
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
        } else {
            outcome = .failure(DownloadError.incomplete)
        }
        lock.withLock { outcomes[downloadTask.taskIdentifier] = outcome }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let id = task.taskIdentifier
        let (waiter, outcome, handler) = lock.withLock { (waiters.removeValue(forKey: id), outcomes.removeValue(forKey: id), unattended) }

        let result: Result<Void, any Error>
        if let error {
            result = .failure((error as? URLError)?.code == .cancelled ? CancellationError() : error)
        } else {
            result = outcome ?? .failure(DownloadError.incomplete)
        }
        if let waiter {
            waiter.continuation.resume(with: result)
        } else {
            handler?()
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.withLock { eventsDelivered = true }
    }
}
