import CryptoKit
import DeviceKit
import Foundation

/// Local copies of phone files for Quick Look and opening in other apps.
@MainActor
public final class PreviewService {
    private let devices: DeviceService
    private let folder = URL.cachesDirectory.appending(path: "app.droidcargo/Previews")

    public init(devices: DeviceService) {
        self.devices = devices
    }

    /// Downloads the file once; later calls reuse the copy while size and date match.
    /// `progress` gets bytes received; cancelling the task stops the download.
    public func localCopy(of item: RemoteItem, on deviceID: String, progress: @escaping ByteProgress = { _ in }) async throws -> URL {
        let digest = SHA256.hash(data: Data("\(deviceID)|\(item.path)|\(item.size)|\(item.modified.timeIntervalSince1970)".utf8))
        let key = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        let target = folder.appending(path: key).appending(path: item.name)
        if FileManager.default.fileExists(atPath: target.path) {
            return target
        }

        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let session = try await devices.session(for: deviceID)
        let partial = target.appendingPathExtension("part")
        do {
            try await session.download(item.path, to: partial, control: TransferControl(), progress: progress)
            try FileManager.default.moveItem(at: partial, to: target)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        return target
    }

    public func clearCache() {
        try? FileManager.default.removeItem(at: folder)
    }
}
