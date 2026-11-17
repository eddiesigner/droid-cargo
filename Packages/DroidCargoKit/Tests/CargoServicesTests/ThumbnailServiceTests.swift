@testable import CargoServices
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// Photos without an embedded preview must not be drawn from the 64 KB
/// prefix: ImageIO decodes the top of the main image and fills the rest gray.
struct ThumbnailServiceTests {
    private static let width = 2000
    private static let height = 1500
    private static let thumbnailSize = 96
    private static let grayTolerance = 12

    @Test(arguments: [UTType.jpeg, UTType.heic])
    func photoWithoutPreviewIsNotHalfGray(_ type: UTType) async throws {
        let (service, session, folder) = Self.makeService()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = Self.put(session, type: type, embedPreview: false)

        let image = try #require(await service.thumbnail(for: item, deviceID: "fake", maxPixelSize: Self.thumbnailSize))

        // The bottom stripe is solid red; a truncated decode leaves it gray.
        let bottom = try #require(Self.pixel(image, x: image.width / 2, y: image.height - 2))
        #expect(bottom.red > 200 && bottom.green < 60, "bottom pixel \(bottom) should be red, not gray")
    }

    @Test func photoWithPreviewReadsOnlyThePrefix() async throws {
        let (service, session, folder) = Self.makeService()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = Self.put(session, type: .jpeg, embedPreview: true)

        _ = try #require(await service.thumbnail(for: item, deviceID: "fake", maxPixelSize: Self.thumbnailSize))

        #expect(session.downloadCount == 0)
    }

    // MARK: Helpers

    private static func makeService() -> (ThumbnailService, FakeSession, URL) {
        let session = FakeSession()
        let folder = FileManager.default.temporaryDirectory.appending(path: "thumbs-\(UUID().uuidString)")
        let service = ThumbnailService(sessions: { _ in session }, cacheFolder: folder)
        return (service, session, folder)
    }

    /// A noisy photo (so it is far bigger than 64 KB) with a solid red bottom stripe.
    private static func put(_ session: FakeSession, type: UTType, embedPreview: Bool) -> RemoteItem {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        var generator = SystemRandomNumberGenerator()
        let block = 10
        for y in stride(from: 0, to: height, by: block) {
            for x in stride(from: 0, to: width, by: block) {
                context.setFillColor(
                    red: .random(in: 0...1, using: &generator),
                    green: .random(in: 0...1, using: &generator),
                    blue: .random(in: 0...1, using: &generator),
                    alpha: 1
                )
                context.fill(CGRect(x: x, y: y, width: block, height: block))
            }
        }
        // CoreGraphics' origin is bottom-left, so this is the image's bottom.
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 5))

        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImageDestinationEmbedThumbnail: embedPreview,
        ]
        CGImageDestinationAddImage(destination, context.makeImage()!, options as CFDictionary)
        CGImageDestinationFinalize(destination)

        let path = "/sdcard/DCIM/photo.\(type.preferredFilenameExtension!)"
        session.put(path, data: data as Data)
        return RemoteItem(path: path, name: RemotePath.name(path), kind: .file, size: UInt64(data.length), modified: Date(timeIntervalSince1970: 0))
    }

    private static func pixel(_ image: CGImage, x: Int, y: Int) -> (red: Int, green: Int, blue: Int)? {
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return nil
        }
        // Draw so that image pixel (x, y) from the top lands on the single output pixel.
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }
}
