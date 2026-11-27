import AVFoundation
import CoreGraphics
import CryptoKit
import DeviceKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Makes small previews of phone files, cached in memory and on disk.
///
/// Reads as little as possible over USB:
///
///   JPEG / HEIC  first 64 KB  ──▶ preview the camera embedded in the file
///   other images whole file   ──▶ downscale (size capped)
///   videos       first 4 MB + last 2 MB, written as a sparse file
///                (first frame + index, wherever the index lives) ──▶ frame 0
public actor ThumbnailService {
    public static let maxImageBytes: UInt64 = 40 * 1024 * 1024
    private static let embeddedPreviewBytes = 64 * 1024
    /// Past this, reading up to a HEIC preview costs about as much as the full-file path.
    private static let maxPreviewReadBytes: UInt64 = 4 * 1024 * 1024
    private static let videoHeadBytes = 4 * 1024 * 1024
    private static let videoTailBytes = 2 * 1024 * 1024
    /// Below this, copying the whole video is simpler than stitching head and tail.
    private static let smallVideoBytes: UInt64 = 8 * 1024 * 1024
    /// Embedded previews smaller than this share of the requested size look blurry.
    private static let embeddedMinimumScale = 0.75
    /// Embedded previews are far smaller than a quarter of the photo.
    private static let previewProbeDivisor = 4
    private static let embeddedFormats: Set<String> = ["jpg", "jpeg", "heic", "heif", "dng", "tif", "tiff"]
    private static let concurrentGenerations = 4
    private static let memoryCacheLimit = 800
    private static let jpegQuality = 0.8
    private static let cacheFolderName = "Thumbnails-3"
    /// Earlier builds cached half-gray (1) and black HEIC (2) thumbnails.
    private static let legacyCacheFolders = ["Thumbnails", "Thumbnails-2"]

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
        let root = URL.cachesDirectory.appending(path: "app.droidcargo")
        // Earlier builds cached broken thumbnails; start over.
        for legacy in Self.legacyCacheFolders {
            try? FileManager.default.removeItem(at: root.appending(path: legacy))
        }
        let folder = root.appending(path: Self.cacheFolderName)
        self.init(sessions: { id in try await devices.session(for: id) }, cacheFolder: folder)
    }

    public static func canPreview(_ item: RemoteItem) -> Bool {
        let category = FileCategory(item)
        return category == .image || category == .video
    }

    /// Returns nil for unsupported files or when generation fails.
    /// Runs in the caller's task, so a cell scrolled out of view cancels its work.
    public func thumbnail(for item: RemoteItem, deviceID: String, maxPixelSize: Int) async -> CGImage? {
        guard Self.canPreview(item) else {
            return nil
        }
        let key = Self.cacheKey(item, deviceID: deviceID, maxPixelSize: maxPixelSize)
        if let cached = memory.object(forKey: key as NSString) {
            return cached.image
        }

        let diskURL = cacheFolder.appending(path: "\(key).jpg")
        if let image = await Self.decode(diskURL, maxPixelSize: maxPixelSize) {
            memory.setObject(CGImageBox(image), forKey: key as NSString)
            return image
        }

        guard (try? await limiter.acquire()) != nil else {
            return nil
        }
        defer { Task { await limiter.release() } }
        guard !Task.isCancelled, let session = try? await sessions(deviceID) else {
            return nil
        }

        guard let image = await Self.render(item, session: session, maxPixelSize: maxPixelSize) else {
            return nil
        }
        Self.writeJPEG(image, to: diskURL)
        memory.setObject(CGImageBox(image), forKey: key as NSString)
        return image
    }

    public func clearCache() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: cacheFolder)
        try? FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
    }

    // MARK: Rendering (runs off the actor so cache hits never wait behind decoding)

    private static func render(_ item: RemoteItem, session: any DeviceSession, maxPixelSize: Int) async -> CGImage? {
        if FileCategory(item) == .video {
            return await videoThumbnail(item, session: session, maxPixelSize: maxPixelSize)
        }

        if embeddedFormats.contains(item.fileExtension),
           let prefix = try? await session.readPrefix(item.path, maxBytes: embeddedPreviewBytes),
           let embedded = embeddedPreview(await completePreviewData(prefix, item: item, session: session), maxPixelSize: maxPixelSize) {
            return embedded
        }

        guard item.size <= maxImageBytes else {
            return nil
        }
        return await withTempCopy(of: item, session: session) { url in
            await decode(url, maxPixelSize: maxPixelSize)
        }
    }

    /// HEIC previews can end past the first read, and a cut-off one decodes
    /// as solid black. Reads up to the preview's end when the file says so.
    private static func completePreviewData(_ prefix: Data, item: RemoteItem, session: any DeviceSession) async -> Data {
        guard let end = HEIFLayout.previewEnd(in: prefix),
              end > prefix.count,
              UInt64(end) <= min(item.size, maxPreviewReadBytes),
              let longer = try? await session.readPrefix(item.path, maxBytes: end) else {
            return prefix
        }
        return longer
    }

    /// The preview the camera stored in the file header, if there is one and it is large enough.
    ///
    /// ImageIO ignores `CreateThumbnailFromImageIfAbsent: false` here: with no
    /// embedded preview it decodes the truncated main image instead, leaving
    /// the missing part gray. Asked with a limit above the preview's size,
    /// a real preview comes back at its own size (160–320 px); a fake one
    /// comes back at the full limit.
    ///
    ///     photo 4000 px, probe limit 1000 ──▶ real preview: 160 px  ✓
    ///                                     ──▶ no preview:  1000 px  ✗ (fall back)
    private static func embeddedPreview(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let photoWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let photoHeight = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        // A quarter of the photo: above any real preview, and a cheap decode when there is none.
        let probeSize = max(photoWidth, photoHeight) / previewProbeDivisor
        var native: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        native[kCGImageSourceThumbnailMaxPixelSize] = probeSize
        guard let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, native as CFDictionary) else {
            return nil
        }
        let previewLongSide = max(preview.width, preview.height)
        guard previewLongSide < probeSize else {
            return nil
        }
        guard Double(previewLongSide) >= Double(maxPixelSize) * embeddedMinimumScale else {
            return nil
        }
        guard previewLongSide > maxPixelSize else {
            return preview
        }

        // Larger than needed: let ImageIO downscale the same embedded preview.
        var scaled = native
        scaled[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize
        return CGImageSourceCreateThumbnailAtIndex(source, 0, scaled as CFDictionary)
    }

    private static func videoThumbnail(_ item: RemoteItem, session: any DeviceSession, maxPixelSize: Int) async -> CGImage? {
        guard item.size > smallVideoBytes else {
            return await withTempCopy(of: item, session: session) { url in
                await videoFrame(url, maxPixelSize: maxPixelSize)
            }
        }

        // Sparse file of the original size holding only the head and tail.
        let temp = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(item.fileExtension)")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            let head = try await session.readPrefix(item.path, maxBytes: videoHeadBytes)
            let tail = try await session.readSuffix(item.path, maxBytes: videoTailBytes)
            FileManager.default.createFile(atPath: temp.path, contents: nil)
            let handle = try FileHandle(forWritingTo: temp)
            defer { try? handle.close() }
            try handle.truncate(atOffset: item.size)
            try handle.seek(toOffset: item.size - UInt64(tail.count))
            try handle.write(contentsOf: tail)
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: head)
        } catch {
            return nil
        }
        return await videoFrame(temp, maxPixelSize: maxPixelSize)
    }

    private static func withTempCopy(
        of item: RemoteItem,
        session: any DeviceSession,
        _ body: (URL) async -> CGImage?
    ) async -> CGImage? {
        let temp = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(item.fileExtension)")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try await session.download(item.path, to: temp, control: TransferControl()) { _ in }
        } catch {
            return nil
        }
        return await body(temp)
    }

    private static func decode(_ url: URL, maxPixelSize: Int) async -> CGImage? {
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
        return try? await generator.image(at: .zero).image
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
