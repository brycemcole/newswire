import ImageIO
import SwiftUI
import UIKit

/// Downloads article images, scales them to display size off the main thread with ImageIO, and keeps the
/// decoded results in memory. `AsyncImage` decodes full-size photos (often 2000px) on the main thread while
/// scrolling and re-downloads them through a tiny default cache; this avoids both.
nonisolated final class ThumbnailLoader: Sendable {
    static let shared = ThumbnailLoader()

    /// Pixel sizes used across the app: list thumbnails (96pt at 3x) and full-width images (feed hero rows and story detail).
    static let small: CGFloat = 288
    static let large: CGFloat = 1200

    nonisolated(unsafe) private let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()
    private let inflight = Inflight()

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "thumbnails")
        configuration.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 300 * 1024 * 1024, directory: directory)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    private static func key(_ url: URL, _ size: CGFloat) -> NSString { "\(Int(size))|\(url.absoluteString)" as NSString }

    /// Synchronous memory lookup, safe to call from a view initializer so cached images appear on the first frame.
    func cached(_ url: URL, size: CGFloat) -> UIImage? {
        memory.object(forKey: Self.key(url, size))
    }

    @concurrent func image(_ url: URL, size: CGFloat) async -> UIImage? {
        if let hit = cached(url, size: size) { return hit }
        return await inflight.run(Self.key(url, size) as String) { [self] in
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  let image = Self.downsample(data, size: size) else { return nil }
            memory.setObject(image, forKey: Self.key(url, size), cost: image.cost)
            return image
        }
    }

    /// Warms the cache a few images at a time; used by background refresh so the feed opens with images ready.
    @concurrent func prefetch(_ requests: [(URL, CGFloat)]) async {
        await withTaskGroup(of: Void.self) { group in
            var pending = requests.makeIterator()
            for _ in 0..<4 {
                guard let next = pending.next() else { break }
                group.addTask { _ = await self.image(next.0, size: next.1) }
            }
            while await group.next() != nil {
                guard !Task.isCancelled, let next = pending.next() else { continue }
                group.addTask { _ = await self.image(next.0, size: next.1) }
            }
        }
    }

    private static func downsample(_ data: Data, size: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: size,
        ] as [CFString: Any] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: image)
    }

    /// Collapses concurrent requests for the same image into one download.
    private actor Inflight {
        private var tasks: [String: Task<UIImage?, Never>] = [:]

        func run(_ key: String, _ work: @escaping @Sendable () async -> UIImage?) async -> UIImage? {
            if let task = tasks[key] { return await task.value }
            let task = Task { await work() }
            tasks[key] = task
            let result = await task.value
            tasks[key] = nil
            return result
        }
    }
}

private extension UIImage {
    nonisolated var cost: Int {
        guard let image = cgImage else { return 1 }
        return image.bytesPerRow * image.height
    }
}

/// A fixed-size image slot: it never changes the layout around it. It shows a placeholder until the
/// downsampled image is ready, then fades it in; a cached image is shown on the first frame with no fade.
/// A failed load keeps the placeholder rather than collapsing the row.
struct ThumbnailImage: View {
    let url: URL
    let size: CGFloat
    @State private var image: UIImage?

    init(url: URL, size: CGFloat) {
        self.url = url
        self.size = size
        let loader = ThumbnailLoader.shared
        _image = State(initialValue: loader.cached(url, size: size) ?? (size > ThumbnailLoader.small ? loader.cached(url, size: ThumbnailLoader.small) : nil))
    }

    var body: some View {
        Rectangle().fill(.quaternary)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
                }
            }
            .clipped()
            .task(id: url) {
                if let image, ThumbnailLoader.shared.cached(url, size: size) === image { return }
                guard let loaded = await ThumbnailLoader.shared.image(url, size: size), !Task.isCancelled else { return }
                if image == nil {
                    withAnimation(.easeOut(duration: 0.2)) { image = loaded }
                } else {
                    image = loaded
                }
            }
    }
}
