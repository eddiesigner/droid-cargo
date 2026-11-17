@testable import ADBKit
import DeviceKit
import Foundation
import ImageIO
import Testing

/// Runs against a real phone. Enable with `DROIDCARGO_DEVICE_TESTS=1 swift test`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DROIDCARGO_DEVICE_TESTS"] == "1"))
struct DeviceIntegrationTests {
    private static let cameraFolder = "/storage/emulated/0/DCIM/Camera"

    private func session() async throws -> any DeviceSession {
        let transport = ADBTransport(client: ADBClient(launcher: ADBServerLauncher()))
        let infos = try await ADBClient(launcher: ADBServerLauncher()).trackDevices().first { _ in true } ?? []
        let info = try #require(infos.first { $0.deviceState == .online })
        let device = Device(id: info.serial, name: info.model, model: info.model, state: .online, transport: .adb)
        return try await transport.openSession(device)
    }

    @Test func listsCameraFolderQuickly() async throws {
        let session = try await session()
        let clock = ContinuousClock()
        var items: [RemoteItem] = []
        let elapsed = try await clock.measure { items = try await session.list(Self.cameraFolder) }
        print("BENCH list \(items.count) items in \(elapsed)")
        #expect(!items.isEmpty)
    }

    @Test func readsEmbeddedJPEGThumbnail() async throws {
        let session = try await session()
        let photo = try #require(try await session.list(Self.cameraFolder).first { $0.fileExtension == "jpg" })
        let clock = ContinuousClock()
        var data = Data()
        let elapsed = try await clock.measure { data = try await session.readPrefix(photo.path, maxBytes: 128 * 1024) }

        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageIfAbsent: false]
        let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        print("BENCH prefix \(data.count) bytes in \(elapsed), photo \(photo.size) bytes, embedded \(thumb.map { "\($0.width)x\($0.height)" } ?? "none")")
        #expect(data.count > 0)
    }
}
