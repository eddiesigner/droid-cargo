import AVFoundation
import CoreGraphics
import CryptoKit
import DeviceKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Makes small previews of phone files, cached in memory and on disk.
///
/// Generating a thumbnail means copying the file to the Mac first, so sizes are
/// capped and only a few run at once to leave USB bandwidth for real transfers.
public actor ThumbnailService {
    public static let maxImageBytes: UInt64 = 60 * 1024 * 1024
    public static let maxVideoBytes: UInt64 = 80 * 1024 * 1024
    private static let concurrentGenerations = 3
    private static let memoryCacheLimit = 600
    private static let jpegQuality = 0.8

    private let sessions: @Sendable (String) async throws -> any DeviceSession
    private let cacheFolder: URL
    private let memory = NSCache<NSString, CGImageBox>()
    private let limiter = AsyncLimiter(limit: concurrentGenerations)

    init(sessions: @escaping @Sendable (String) async throws -> any DeviceSession, cacheFolder: URL) {
        self.sessions = sessions
        self.cacheFolder = cacheFolder
        memory.countLimit = Self.memoryCacheLimit
        try? FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
    }

    public init(devices: DeviceService) {
        let folder = URL.cachesDirectory.appending(path: "app.droidcargo/Thumbnails")
        self.init(sessions: { id in try await devices.session(for: id) }, cacheFolder: folder)
    }

    public static func canPreview(_ item: RemoteItem) -> Bool {
        switch FileCategory(item) {
        case .image:
            return item.size <= maxImageBytes
        case .video:
            return item.size <= maxVideoBytes
        default:
            return false
        }
    }

    /// Returns nil for unsupported files or when generation fails. Cancellation-aware.
    public func thumbnail(for item: RemoteItem, deviceID: String, maxPixelSize: Int) async -> CGImage? {
        guard Self.canPreview(item) else {
            return nil
        }
        let key = Self.cacheKey(item, deviceID: deviceID, maxPixelSize: maxPixelSize)
        if let cached = memory.object(forKey: key as NSString) {
            return cached.image
        }
        // Runs in the caller's task so scrolling a cell away cancels its work.
        return await generate(item, deviceID: deviceID, maxPixelSize: maxPixelSize, key: key)
    }

    public func clearCache() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: cacheFolder)
        try? FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
    }

    private func generate(_ item: RemoteItem, deviceID: String, maxPixelSize: Int, key: String) async -> CGImage? {
        let diskURL = cacheFolder.appending(path: "\(key).jpg")
        if let image = Self.loadImage(diskURL, maxPixelSize: maxPixelSize) {
            memory.setObject(CGImageBox(image), forKey: key as NSString)
            return image
        }

        guard (try? await limiter.acquire()) != nil else {
            return nil
        }
        defer { Task { await limiter.release() } }
        if Task.isCancelled {
            return nil
        }

        // Copy the original to a temp file, render, then throw the copy away.
        let temp = FileManager.default.temporaryDirectory.appending(path: "\(key).\(item.fileExtension)")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            let session = try await sessions(deviceID)
            try await session.download(item.path, to: temp, control: TransferControl()) { _ in }
        } catch {
            return nil
        }

        let image: CGImage?
        if FileCategory(item) == .video {
            image = await Self.videoFrame(temp, maxPixelSize: maxPixelSize)
        } else {
            image = Self.loadImage(temp, maxPixelSize: maxPixelSize)
        }
        guard let image else {
            return nil
        }
        Self.writeJPEG(image, to: diskURL)
        memory.setObject(CGImageBox(image), forKey: key as NSString)
        return image
    }

    // MARK: Rendering

    private static func loadImage(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func videoFrame(_ url: URL, maxPixelSize: Int) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        return try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
    }

    private static func writeJPEG(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    static func cacheKey(_ item: RemoteItem, deviceID: String, maxPixelSize: Int) -> String {
        let raw = "\(deviceID)|\(item.path)|\(item.size)|\(item.modified.timeIntervalSince1970)|\(maxPixelSize)"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private final class CGImageBox {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}

/// Counting semaphore for async code, last in first out.
actor AsyncLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async throws {
        if running < limit {
            running += 1
            return
        }
        // The releasing task hands its slot over on resume.
        await withCheckedContinuation { waiters.append($0) }
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    /// Wakes the newest waiter first: the cells the user is looking at right now.
    func release() {
        guard let next = waiters.popLast() else {
            running -= 1
            return
        }
        next.resume()
    }
}
