@testable import ADBKit
import Foundation
import Synchronization
import Testing

/// Downloads the real archive from Google, so it only runs on request:
/// `DROIDCARGO_NETWORK_TESTS=1 swift test --filter PlatformToolsInstallerTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DROIDCARGO_NETWORK_TESTS"] == "1"))
struct PlatformToolsInstallerTests {
    @Test func installsRunnableADB() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "droidcargo-tools-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let installer = PlatformToolsInstaller(directory: directory)
        let stages = Mutex<[PlatformToolsInstaller.Stage]>([])

        try await installer.install { stage in stages.withLock { $0.append(stage) } }

        #expect(FileManager.default.isExecutableFile(atPath: installer.adbURL.path))
        let seen = stages.withLock { $0 }
        #expect(seen.contains(.downloading(fraction: 1)))
        #expect(seen.last == .unpacking)

        // Only adb's folder remains: the zip and staging folder are cleaned up.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(leftovers == ["platform-tools"])

        // A launcher limited to the app's own install finds it.
        let launcher = ADBServerLauncher(installer: installer, scope: .appInstallOnly)
        #expect(launcher.locate() == installer.adbURL)
    }
}
