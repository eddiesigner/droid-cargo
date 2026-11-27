@testable import ADBKit
@testable import CargoServices
import CoreGraphics
import Foundation
import ImageIO
import Testing

/// Checks real camera photos for half-gray thumbnails. Enable with `DROIDCARGO_DEVICE_TESTS=1`.
/// Only pixel statistics are read; no image is saved or shown.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DROIDCARGO_DEVICE_TESTS"] == "1"))
struct ThumbnailDeviceTests {
    private static let cameraFolder = "/storage/emulated/0/DCIM/Camera"
    private static let sampleCount = 40
    private static let prefixBytes = 64 * 1024
    private static let sizes = [128, 240]
    /// ImageIO fills undecoded JPEG rows with this gray.
    private static let fillGray = 128

    @Test func cameraThumbnailsAreNotHalfGray() async throws {
        let client = ADBClient(launcher: ADBServerLauncher())
        let infos = try await client.trackDevices().first { _ in true } ?? []
        let info = try #require(infos.first { $0.deviceState == .online })
        let device = Device(id: info.serial, name: info.model, model: info.model, state: .online, transport: .adb)
        let session = try await ADBTransport(client: client).openSession(device)

        // The files from the bug report sort first ("0c…", "0d…").
        let samples = try await session.list(Self.cameraFolder)
            .filter { $0.fileExtension == "jpg" }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
            .prefix(Self.sampleCount)
        let cache = FileManager.default.temporaryDirectory.appending(path: "thumb-device-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let service = ThumbnailService(sessions: { _ in session }, cacheFolder: cache)

        var oldWayGray = 0
        var grayNow = 0
        for item in samples {
            // What the previous code did: decode the 64 KB prefix as a thumbnail.
            let prefix = try await session.readPrefix(item.path, maxBytes: Self.prefixBytes)
            if let source = CGImageSourceCreateWithData(prefix as CFData, nil),
               let old = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                   kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                   kCGImageSourceThumbnailMaxPixelSize: Self.sizes[1],
               ] as CFDictionary),
               Self.hasGrayBottom(old) {
                oldWayGray += 1
            }
            for size in Self.sizes {
                if let image = await service.thumbnail(for: item, deviceID: device.id, maxPixelSize: size), Self.hasGrayBottom(image) {
                    grayNow += 1
                }
            }
        }
        print("DEVICE gray-bottom: \(oldWayGray)/\(samples.count) with old prefix decode, \(grayNow) now")
        #expect(grayNow == 0)
    }

    /// iPhone HEICs often store their preview past the first 64 KB; decoded
    /// from the prefix it came out black (reported for IMG_0006 / IMG_0007).
    @Test func heicThumbnailsAreNotBlack() async throws {
        let client = ADBClient(launcher: ADBServerLauncher())
        let infos = try await client.trackDevices().first { _ in true } ?? []
        let info = try #require(infos.first { $0.deviceState == .online })
        let device = Device(id: info.serial, name: info.model, model: info.model, state: .online, transport: .adb)
        let session = try await ADBTransport(client: client).openSession(device)

        let samples = try await session.list(Self.cameraFolder)
            .filter { $0.fileExtension == "heic" && $0.name.hasPrefix("IMG_00") }
            .sorted { $0.name < $1.name }
            .prefix(Self.heicSampleCount)
        let cache = FileManager.default.temporaryDirectory.appending(path: "thumb-heic-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let service = ThumbnailService(sessions: { _ in session }, cacheFolder: cache)

        var black: [String] = []
        for item in samples {
            guard let image = await service.thumbnail(for: item, deviceID: device.id, maxPixelSize: Self.sizes[0]) else {
                continue
            }
            if Self.meanBrightness(image) < Self.blackLevel {
                black.append(item.name)
            }
        }
        print("DEVICE black HEIC thumbnails: \(black.count)/\(samples.count) \(black)")
        #expect(black.isEmpty)
    }

    private static let heicSampleCount = 20
    /// Mean 0–255 brightness below which a thumbnail counts as black.
    private static let blackLevel = 3.0

    private static func meanBrightness(_ image: CGImage) -> Double {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return 0
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let total = stride(from: 0, to: pixels.count, by: 4).reduce(0) { $0 + Int(pixels[$1]) + Int(pixels[$1 + 1]) + Int(pixels[$1 + 2]) }
        return Double(total) / Double(side * side * 3)
    }

    /// True when the bottom row is a flat fill of ImageIO's gray.
    private static func hasGrayBottom(_ image: CGImage) -> Bool {
        let width = image.width
        var row = [UInt8](repeating: 0, count: width * 4)
        guard let context = CGContext(
            data: &row, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return false
        }
        // Shift the image so its bottom row lands in the 1-pixel-tall context.
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: image.height))
        return stride(from: 0, to: row.count, by: 4).allSatisfy {
            abs(Int(row[$0]) - fillGray) <= 2 && abs(Int(row[$0 + 1]) - fillGray) <= 2 && abs(Int(row[$0 + 2]) - fillGray) <= 2
        }
    }
}
