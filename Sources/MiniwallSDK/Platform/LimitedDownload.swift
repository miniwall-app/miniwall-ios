#if os(iOS)
import Foundation
import MiniwallCore

/// What a size-limited download ended with.
enum LimitedDownloadResult {
    case data(Data)
    /// `Content-Length` was over the limit, or the bytes received passed it (the transfer was cancelled).
    case tooLarge
    /// Network error, non-2xx status, or the calling task was cancelled.
    case failed
}

/// One download read in chunks by `URLSessionDataDelegate` (not byte by byte from `AsyncBytes`): refused before
/// the body when `Content-Length` is over `max`, cancelled the moment the running total would pass `max`, and
/// never holding more than `max` bytes (`LimitedBuffer` drops the chunk that would pass it).
/// Every callback runs on the session's serial delegate queue; `lock` guards the state the calling task also touches.
final class LimitedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let max: Int64
    private let lock = NSLock()
    private var buffer: LimitedBuffer
    private var continuation: CheckedContinuation<LimitedDownloadResult, Never>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var isCancelled = false

    private init(max: Int64) {
        self.max = max
        self.buffer = LimitedBuffer(max: max)
    }

    /// Downloads `request` with at most `max` bytes. `configuration` is copied from the caller's session so its
    /// cache and timeouts apply. Never throws; logs (NSLog) when it refuses or fails.
    static func fetch(_ request: URLRequest, max: Int64, configuration: URLSessionConfiguration) async -> LimitedDownloadResult {
        let job = LimitedDownload(max: max)
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<LimitedDownloadResult, Never>) in
                job.start(request, configuration: configuration, continuation: continuation)
            }
        } onCancel: {
            job.cancel()
        }
        if case .tooLarge = result {
            NSLog("Miniwall: download refused, larger than %lld bytes: %@", max, request.url?.absoluteString ?? "?")
        }
        return result
    }

    private func start(_ request: URLRequest, configuration: URLSessionConfiguration, continuation: CheckedContinuation<LimitedDownloadResult, Never>) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            continuation.resume(returning: .failed)
            return
        }
        self.continuation = continuation
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1 // serial: delegate callbacks never overlap
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: request)
        self.session = session
        self.task = task
        lock.unlock()
        task.resume()
    }

    private func cancel() {
        lock.lock()
        isCancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel() // didCompleteWithError(cancelled) then finishes with .failed
    }

    /// Resumes the caller exactly once and releases the session (it retains this object as its delegate).
    private func finish(_ result: LimitedDownloadResult) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        self.task = nil
        lock.unlock()
        guard let continuation else { return }
        session?.invalidateAndCancel()
        continuation.resume(returning: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            completionHandler(.cancel)
            finish(.failed)
            return
        }
        // -1 when the server does not say; then only the running total can stop the transfer.
        let declared = response.expectedContentLength
        if DownloadLimits.declaredTooLarge(declared, max: max) {
            completionHandler(.cancel)
            finish(.tooLarge)
            return
        }
        lock.lock()
        buffer = LimitedBuffer(max: max, expectedLength: declared)
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let accepted = buffer.append(data)
        lock.unlock()
        if !accepted {
            dataTask.cancel()
            finish(.tooLarge)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil {
            finish(.failed) // no-op when a limit or status already finished it
            return
        }
        lock.lock()
        let data = buffer.data
        lock.unlock()
        finish(.data(data))
    }
}
#endif
