#if os(iOS)
import SwiftUI
import UIKit

/// Downloads images once (memory + URL cache) for screens, icons and backgrounds. `preload`
/// fills it before a screen shows, so it opens without blank images.
final class ImageLoader {
    static let shared = ImageLoader()
    private let cache = NSCache<NSURL, UIImage>()
    private var waiting: [URL: [(UIImage?) -> Void]] = [:]
    private let lock = NSLock()
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 64 << 20)
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    func load(_ url: URL, completion: @escaping (UIImage?) -> Void) {
        if let image = cached(url) { return completion(image) }
        lock.lock()
        if waiting[url] != nil {
            waiting[url]!.append(completion)
            lock.unlock()
            return
        }
        waiting[url] = [completion]
        lock.unlock()
        Task { [weak self] in
            guard let self else { return }
            // Read in chunks with a size limit: refused on a larger Content-Length, cancelled once the bytes pass the limit.
            var image: UIImage?
            switch await LimitedDownload.fetch(URLRequest(url: url), max: DownloadLimits.maxImageBytes, configuration: self.session.configuration) {
            case .data(let data): image = UIImage(data: data)
            case .tooLarge: NSLog("Miniwall: image skipped, larger than %lld bytes: %@", DownloadLimits.maxImageBytes, url.absoluteString)
            case .failed: image = nil
            }
            if let image { self.cache.setObject(image, forKey: url as NSURL) }
            self.lock.lock()
            let callbacks = self.waiting.removeValue(forKey: url) ?? []
            self.lock.unlock()
            let loaded = image
            await MainActor.run { callbacks.forEach { $0(loaded) } }
        }
    }

    func load(_ url: URL) async -> UIImage? {
        await withCheckedContinuation { continuation in load(url) { continuation.resume(returning: $0) } }
    }
}

/// A remote image; empty until loaded (never a broken-image icon).
struct RemoteImage<Content: View>: View {
    let url: String
    @ViewBuilder let content: (UIImage) -> Content
    /// The image last loaded and the link it was loaded for: never shown for a different link.
    @State private var loaded: (url: String, image: UIImage)?

    var body: some View {
        Group {
            if let image = URL(string: url).flatMap(ImageLoader.shared.cached) ?? loaded.flatMap({ $0.url == url ? $0.image : nil }) {
                content(image)
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            guard let u = URL(string: url) else { return }
            let requested = url
            let image = await ImageLoader.shared.load(u)
            loaded = image.map { (requested, $0) }
        }
    }
}

/// SVG icons (the templates' icons are SVG files, which UIImage cannot read), parsed once per URL.
final class IconLoader {
    static let shared = IconLoader()
    private var icons: [URL: SvgIcon] = [:]
    private var failed: Set<URL> = []
    private let lock = NSLock()
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 2 << 20, diskCapacity: 16 << 20)
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    /// The parsed icon: the SVG the server delivered for it first, else one already downloaded from the link.
    func cached(_ url: URL) -> SvgIcon? {
        lock.lock()
        let known = icons[url]
        lock.unlock()
        if let known { return known }
        guard let markup = DeliveredAssets.shared.iconMarkup(url.absoluteString), let icon = Svg.parse(markup) else { return nil }
        lock.lock()
        icons[url] = icon
        lock.unlock()
        return icon
    }

    func load(_ url: URL, completion: @escaping (SvgIcon?) -> Void) {
        if let icon = cached(url) { return completion(icon) }
        lock.lock()
        let known = failed.contains(url)
        lock.unlock()
        if known { return completion(nil) }
        session.dataTask(with: url) { [weak self] data, _, _ in
            let icon = data.flatMap { String(data: $0, encoding: .utf8) }.flatMap(Svg.parse)
            guard let self else { return }
            self.lock.lock()
            if let icon { self.icons[url] = icon } else { self.failed.insert(url) }
            self.lock.unlock()
            DispatchQueue.main.async { completion(icon) }
        }.resume()
    }
}
#endif
