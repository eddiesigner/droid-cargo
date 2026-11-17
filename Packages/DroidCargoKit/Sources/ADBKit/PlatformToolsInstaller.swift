import Foundation

/// Downloads Google's Android Platform Tools into a folder DroidCargo owns,
/// so nobody needs Homebrew or Terminal.
///
///     <directory>/
///       platform-tools/adb      ← used by ADBServerLauncher
///       download-<uuid>.zip     ← removed after unpacking
public struct PlatformToolsInstaller: Sendable {
    public enum Stage: Sendable, Equatable {
        case downloading(fraction: Double)
        case unpacking
    }

    public enum Failure: LocalizedError {
        case downloadFailed(statusCode: Int)
        case unpackFailed
        case adbDoesNotRun

        public var errorDescription: String? {
            switch self {
            case .downloadFailed(let code):
                String(localized: "The download failed (HTTP \(code)). Check your internet connection and try again.")
            case .unpackFailed:
                String(localized: "The downloaded file could not be unpacked.")
            case .adbDoesNotRun:
                String(localized: "The installed tools did not start.")
            }
        }
    }

    public static let downloadURL = URL(string: "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip")!
    public static let termsURL = URL(string: "https://developer.android.com/studio/terms")!
    private static let archiveFolder = "platform-tools"
    private static let ditto = URL(filePath: "/usr/bin/ditto")
    private static let httpOK = 200
    /// Bytes written per disk write and per progress report.
    private static let chunkSize = 256 * 1024

    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "DroidCargo/PlatformTools", directoryHint: .isDirectory)
    }

    public let directory: URL

    public init(directory: URL = PlatformToolsInstaller.defaultDirectory) {
        self.directory = directory
    }

    public var adbURL: URL {
        directory.appending(path: "\(Self.archiveFolder)/adb")
    }

    /// Downloads, unpacks, and checks that adb runs.
    public func install(stage: @escaping @Sendable (Stage) -> Void) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let zip = directory.appending(path: "download-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: zip) }

        try await download(to: zip, stage: stage)
        stage(.unpacking)
        try await unpack(zip)
        guard try await Self.run(adbURL, ["version"]) == 0 else {
            throw Failure.adbDoesNotRun
        }
    }

    // MARK: Steps

    private func download(to destination: URL, stage: @Sendable (Stage) -> Void) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: Self.downloadURL)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == Self.httpOK else {
            throw Failure.downloadFailed(statusCode: status)
        }

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        // Buffer bytes so the disk sees large writes and the UI a few updates.
        let expected = response.expectedContentLength
        var buffer = Data(capacity: Self.chunkSize)
        var received: Int64 = 0
        stage(.downloading(fraction: 0))
        for try await byte in bytes {
            buffer.append(byte)
            guard buffer.count == Self.chunkSize else {
                continue
            }
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
            buffer.removeAll(keepingCapacity: true)
            if expected > 0 {
                stage(.downloading(fraction: min(1, Double(received) / Double(expected))))
            }
        }
        try handle.write(contentsOf: buffer)
        stage(.downloading(fraction: 1))
    }

    /// Unzips next to the old copy, then swaps it in, so a failed update
    /// never leaves a half-written adb behind.
    private func unpack(_ zip: URL) async throws {
        let fileManager = FileManager.default
        let staging = directory.appending(path: "staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: staging) }

        guard try await Self.run(Self.ditto, ["-x", "-k", zip.path, staging.path]) == 0 else {
            throw Failure.unpackFailed
        }
        let unpacked = staging.appending(path: Self.archiveFolder, directoryHint: .isDirectory)
        guard fileManager.isExecutableFile(atPath: unpacked.appending(path: "adb").path) else {
            throw Failure.unpackFailed
        }

        let target = directory.appending(path: Self.archiveFolder, directoryHint: .isDirectory)
        try? fileManager.removeItem(at: target)
        try fileManager.moveItem(at: unpacked, to: target)
    }

    private static func run(_ executable: URL, _ arguments: [String]) async throws -> Int32 {
        try await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }.value
    }
}
