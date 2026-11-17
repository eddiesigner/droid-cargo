import DeviceKit
import Foundation

/// Finds an `adb` binary and starts its server.
public struct ADBServerLauncher: Sendable {
    /// Checked in order after the user's custom path.
    public static let standardLocations: [String] = [
        "/opt/homebrew/bin/adb",
        "/usr/local/bin/adb",
        NSString(string: "~/Library/Android/sdk/platform-tools/adb").expandingTildeInPath,
    ]

    private let customPath: @Sendable () -> String?

    /// `customPath` is read on every launch so settings changes apply without restarting.
    public init(customPath: @escaping @Sendable () -> String? = { nil }) {
        self.customPath = customPath
    }

    public func locate() -> URL? {
        let bundled = Bundle.main.url(forResource: "adb", withExtension: nil)?.path
        let candidates = [customPath(), bundled].compactMap { $0 } + Self.standardLocations
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(filePath: $0) }
    }

    func startServer() async throws {
        guard let adb = locate() else {
            throw DeviceError.transportUnavailable(
                String(localized: "Android Platform Tools (adb) was not found. Install it with Homebrew or choose its location in Settings.")
            )
        }

        try await Task.detached {
            let process = Process()
            process.executableURL = adb
            process.arguments = ["start-server"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw DeviceError.transportUnavailable(String(localized: "adb could not start (exit code \(process.terminationStatus))."))
            }
        }.value
    }
}
