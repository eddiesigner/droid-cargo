@testable import ADBKit
@testable import CargoServices
import Foundation
import Testing

/// Measures thumbnail generation on a real phone. Enable with `DROIDCARGO_DEVICE_TESTS=1`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DROIDCARGO_DEVICE_TESTS"] == "1"))
struct ThumbnailBenchmarkTests {
    private static let cameraFolder = "/storage/emulated/0/DCIM/Camera"
    private static let samplesPerType = 5
    private static let gridPixels = 256

    @Test(arguments: ["jpg", "heic", "mov", "mp4", "png"])
    func generatesThumbnails(fileExtension: String) async throws {
        let client = ADBClient(launcher: ADBServerLauncher())
        let infos = try await client.trackDevices().first { _ in true } ?? []
        let info = try #require(infos.first { $0.deviceState == .online })
        let device = Device(id: info.serial, name: info.model, model: info.model, state: .online, transport: .adb)
        let session = try await ADBTransport(client: client).openSession(device)

        let samples = try await session.list(Self.cameraFolder)
            .filter { $0.fileExtension == fileExtension }
            .prefix(Self.samplesPerType)
        guard !samples.isEmpty else {
            return
        }
        let cache = FileManager.default.temporaryDirectory.appending(path: "thumb-bench-\(UUID().uuidString)")
        let service = ThumbnailService(sessions: { _ in session }, cacheFolder: cache)

        let clock = ContinuousClock()
        var made = 0
        let elapsed = await clock.measure {
            for item in samples where await service.thumbnail(for: item, deviceID: device.id, maxPixelSize: Self.gridPixels) != nil {
                made += 1
            }
        }
        let average = elapsed / samples.count
        let averageSize = samples.reduce(0) { $0 + $1.size } / UInt64(samples.count)
        print("BENCH thumb .\(fileExtension): \(made)/\(samples.count) made, avg \(average) per file, avg file \(averageSize / 1_048_576) MB")
        try? FileManager.default.removeItem(at: cache)
        #expect(made == samples.count)
    }
}
