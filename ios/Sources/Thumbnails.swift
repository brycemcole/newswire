import CryptoKit
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Downloads article images, scales them to display size off the main thread with ImageIO, keeps the decoded
/// results in memory and the scaled files on disk, so images survive relaunches without another download.
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
    private let disk = DiskStore()

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        // The scaled copies on disk are the cache; keeping full-size originals as well would double the storage.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    private static func key(_ url: URL, _ size: CGFloat) -> NSString { "\(Int(size))|\(url.absoluteString)" as NSString }

    /// Synchronous memory lookup, safe to call from a view initializer so cached images appear on the first frame.
    func cached(_ url: URL, size: CGFloat) -> UIImage? {
        memory.object(forKey: Self.key(url, size))
    }

    /// Memory, then disk. Never touches the network.
    @concurrent func stored(_ url: URL, size: CGFloat) async -> UIImage? {
        let key = Self.key(url, size)
        if let hit = memory.object(forKey: key) { return hit }
        guard let data = await disk.read(key as String), let image = Self.decode(data) else { return nil }
        memory.setObject(image, forKey: key, cost: image.cost)
        return image
    }

    @concurrent func image(_ url: URL, size: CGFloat) async -> UIImage? {
        if let hit = await stored(url, size: size) { return hit }
        let name = Self.key(url, size) as String
        return await inflight.run(name) { [self] in
            let key = name as NSString
            if let hit = memory.object(forKey: key) { return hit }
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  let (image, encoded) = Self.downsample(data, size: size) else { return nil }
            memory.setObject(image, forKey: key, cost: image.cost)
            await disk.write(encoded, for: key as String)
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

    /// Returns the scaled image and the file to keep on disk: the original bytes when they are already small
    /// enough, otherwise the scaled image as JPEG.
    private static func downsample(_ data: Data, size: CGFloat) -> (UIImage, Data)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: size,
        ] as [CFString: Any] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? CGFloat ?? .infinity
        let height = properties?[kCGImagePropertyPixelHeight] as? CGFloat ?? .infinity
        if max(width, height) <= size, data.count <= 600_000 { return (UIImage(cgImage: image), data) }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (UIImage(cgImage: image), output as Data)
    }

    private static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
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

    /// Scaled image files in Caches, evicted least recently used first once they pass the budget.
    private actor DiskStore {
        private static let budget = 320 * 1024 * 1024
        private static let trimmedSize = 260 * 1024 * 1024
        private let directory: URL
        private var total: Int?

        init() {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            directory = caches.appending(path: "images-v1")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // The old URLCache of full-size originals.
            try? FileManager.default.removeItem(at: caches.appending(path: "thumbnails"))
        }

        private func file(_ key: String) -> URL {
            directory.appending(path: SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined())
        }

        func read(_ key: String) -> Data? {
            let url = file(key)
            guard let data = try? Data(contentsOf: url) else { return nil }
            try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: url.path)
            return data
        }

        func write(_ data: Data, for key: String) {
            guard (try? data.write(to: file(key), options: .atomic)) != nil else { return }
            total = (total ?? measure()) + data.count
            if let total, total > Self.budget { trim() }
        }

        private func entries() -> [(url: URL, size: Int, used: Date)] {
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
            return files.compactMap { url in
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
                return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
            }
        }

        private func measure() -> Int { entries().reduce(0) { $0 + $1.size } }

        private func trim() {
            var size = 0
            for entry in entries().sorted(by: { $0.used > $1.used }) {
                if size + entry.size <= Self.trimmedSize {
                    size += entry.size
                } else {
                    try? FileManager.default.removeItem(at: entry.url)
                }
            }
            total = size
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
                let loader = ThumbnailLoader.shared
                if let image, loader.cached(url, size: size) === image { return }
                // Images already on disk replace the placeholder at once; only downloads fade in.
                if let stored = await loader.stored(url, size: size) {
                    guard !Task.isCancelled else { return }
                    image = stored
                    return
                }
                guard let loaded = await loader.image(url, size: size), !Task.isCancelled else { return }
                if image == nil {
                    withAnimation(.easeOut(duration: 0.2)) { image = loaded }
                } else {
                    image = loaded
                }
            }
    }
}
