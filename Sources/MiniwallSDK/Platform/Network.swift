import Foundation
import MiniwallCore

/// UserDefaults-backed storage for the visitor id, frequency caps and exposures.
final class DefaultsStore: KeyValueStore {
    private let defaults: UserDefaults
    init(_ defaults: UserDefaults = UserDefaults(suiteName: "com.miniwall.sdk") ?? .standard) { self.defaults = defaults }
    func get(_ key: String) -> String? { defaults.string(forKey: key) }
    func set(_ key: String, _ value: String?) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

/// The delivery API (`/v1/sdk/...`): fetches with ETag revalidation, keeps the last copy on
/// disk so a published screen still shows offline, and queues analytics events.
final class MiniwallClient {
    var apiKey: String?
    var apiURL = URL(string: Miniwall.defaultAPIURL)!
    var timeout: TimeInterval = 8
    var analytics = true

    private let session: URLSession
    private let cacheDir: URL
    private let queue = DispatchQueue(label: "com.miniwall.sdk.client")
    private var memory: [String: (etag: String?, body: JSONValue)] = [:]

    init() {
        let config = URLSessionConfiguration.default
        // The SDK keeps its own copy and revalidates by ETag: a new publish shows on the next load.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        session = URLSession(configuration: config)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        cacheDir = caches.appendingPathComponent("miniwall", isDirectory: true)
        eventsFile = cacheDir.appendingPathComponent("events.json")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    private func cacheFile(_ key: String) -> URL {
        let safe = key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return cacheDir.appendingPathComponent("\(safe.suffix(120)).json")
    }

    private func readCache(_ key: String) -> (etag: String?, body: JSONValue)? {
        if let m = queue.sync(execute: { memory[key] }) { return m }
        guard let data = try? Data(contentsOf: cacheFile(key)), let entry = try? JSONValue.parse(data), let body = entry["body"] else { return nil }
        return (entry.str("etag"), body)
    }

    private func writeCache(_ key: String, _ entry: (etag: String?, body: JSONValue)) {
        queue.sync { memory[key] = entry }
        var o: [String: JSONValue] = ["body": entry.body]
        if let etag = entry.etag { o["etag"] = .string(etag) }
        try? Data(JSONValue.object(o).jsonString.utf8).write(to: cacheFile(key), options: .atomic)
    }

    /// GET `/v1/sdk<path>`. Network or server failure falls back to the last copy this device saw.
    func fetch(_ path: String, query: [URLQueryItem] = []) async throws -> JSONValue {
        let body = try await fetchBody(path, query: query)
        DeliveredAssets.shared.register(Assets.of(body))
        return body
    }

    private func fetchBody(_ path: String, query: [URLQueryItem]) async throws -> JSONValue {
        guard let apiKey else { throw MiniwallError("Miniwall: call Miniwall.configure(apiKey:) before loading a placement") }
        // `path` is already percent-encoded (placement names): set it as the encoded path so it is not encoded twice.
        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)!
        var base = components.percentEncodedPath
        while base.hasSuffix("/") { base.removeLast() }
        components.percentEncodedPath = base + "/v1/sdk" + path
        components.queryItems = [URLQueryItem(name: "key", value: apiKey), URLQueryItem(name: "v", value: "2")] + query
        let url = components.url!
        let cacheKey = path
        let cached = readCache(cacheKey)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("ios/\(Miniwall.version)", forHTTPHeaderField: "X-Miniwall-SDK")
        if let app = Miniwall.appHeader { request.setValue(app, forHTTPHeaderField: "X-Miniwall-App") }
        if let etag = cached?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let data: Data
        let response: HTTPURLResponse
        do {
            let (d, r) = try await session.data(for: request)
            data = d
            response = r as! HTTPURLResponse
        } catch {
            if let cached { return cached.body }
            if (error as? URLError)?.code == .timedOut { throw MiniwallError("Miniwall: the screen took too long to load") }
            throw error
        }
        if response.statusCode == 304, let cached { return cached.body }
        guard (200..<300).contains(response.statusCode) else {
            if let cached, response.statusCode >= 500 { return cached.body }
            let message = (try? JSONValue.parse(data))?.obj("error")?.str("message")
            throw MiniwallError("Miniwall: \(message ?? "could not load the screen (\(response.statusCode))")")
        }
        let body = try JSONValue.parse(data)
        writeCache(cacheKey, (response.value(forHTTPHeaderField: "ETag"), body))
        return body
    }

    // MARK: Events

    private let eventsFile: URL
    private var pending: [JSONValue] = []
    private var flushScheduled = false
    /// One request at a time: two overlapping flushes would send the same batch twice and drop unsent events.
    private var inFlight = false
    private static let maxAgeMs: Int64 = 7 * 86_400_000

    /// Queues an event; sent in batches every 2 seconds (or at 50), kept on disk until sent (7 days at most).
    func enqueue(_ event: JSONValue) {
        guard analytics, apiKey != nil else { return }
        queue.async {
            if self.pending.isEmpty, let data = try? Data(contentsOf: self.eventsFile), let saved = try? JSONValue.parse(data).arrayValue {
                self.pending = saved
            }
            self.pending.append(event)
            self.persist()
            if self.pending.count >= Events.maxBatch { self.flushNow() } else if !self.flushScheduled {
                self.flushScheduled = true
                self.queue.asyncAfter(deadline: .now() + 2) { self.flushNow() }
            }
        }
    }

    func flush() { queue.async { self.flushNow() } }

    private func persist() {
        try? Data(JSONValue.array(pending).jsonString.utf8).write(to: eventsFile, options: .atomic)
    }

    private func flushNow() {
        flushScheduled = false
        guard !inFlight, let apiKey, !pending.isEmpty else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let cutoff = IsoTime.format(now - Self.maxAgeMs)
        let batch = Array(pending.prefix(Events.maxBatch)).filter { ($0.str("occurredAt") ?? "") >= cutoff }
        let sentCount = min(pending.count, Events.maxBatch)
        guard !batch.isEmpty else {
            pending.removeFirst(sentCount)
            persist()
            return
        }
        var components = URLComponents(url: apiURL.appendingPathComponent("v1/sdk/events"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ios/\(Miniwall.version)", forHTTPHeaderField: "X-Miniwall-SDK")
        if let app = Miniwall.appHeader { request.setValue(app, forHTTPHeaderField: "X-Miniwall-App") }
        request.httpBody = Data(Events.batches(batch).first!.utf8)
        inFlight = true
        session.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            self.queue.async {
                self.inFlight = false
                // Sent, or rejected for good (4xx): drop it. Network/server errors: keep and retry later.
                if error == nil && status < 500 {
                    self.pending.removeFirst(min(sentCount, self.pending.count))
                    self.persist()
                    if !self.pending.isEmpty { self.flushNow() }
                } else if !self.flushScheduled {
                    self.flushScheduled = true
                    self.queue.asyncAfter(deadline: .now() + 30) { self.flushNow() }
                }
            }
        }.resume()
    }
}

extension Events {
    static let maxBatch = 50
}


/// Icons and font links the server delivered next to screens (`assets`). Kept for the process:
/// a name always maps to the same file, so what an earlier screen brought serves a later one.
final class DeliveredAssets {
    static let shared = DeliveredAssets()
    private var assets = DeliveryAssets()
    private let lock = NSLock()

    func register(_ delivered: DeliveryAssets) {
        lock.lock(); defer { lock.unlock() }
        assets = assets + delivered
    }

    /// SVG markup the server sent for the icon this link points at, if any.
    func iconMarkup(_ url: String) -> String? {
        guard let key = Assets.iconKey(url) else { return nil }
        lock.lock(); defer { lock.unlock() }
        return assets.icons[key]
    }

    func fontLink(name: String, declaration: JSONValue?) -> String? {
        lock.lock()
        let current = assets
        lock.unlock()
        return Assets.fontLink(name: name, declaration: declaration, platform: "ios", assets: current)
    }
}
