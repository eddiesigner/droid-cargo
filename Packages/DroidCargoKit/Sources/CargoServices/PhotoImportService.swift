import DeviceKit
import Foundation

/// Finds photos and videos on a phone that were not imported before.
@MainActor
public final class PhotoImportService {
    /// Camera and screenshot folders, relative to each storage root.
    private static let mediaFolders = ["DCIM", "Pictures", "Movies"]

    private let files: FileService
    private let ledgerFolder = URL.applicationSupportDirectory.appending(path: "DroidCargo/Imports")

    public init(files: FileService) {
        self.files = files
    }

    /// Lists media files under the camera folders that are not in the import ledger.
    public func scan(deviceID: String, storages: [Storage]) async throws -> [RemoteItem] {
        let imported = ledger(for: deviceID)
        var found: [RemoteItem] = []
        var pending = storages.flatMap { storage in
            Self.mediaFolders.map { RemotePath.join(storage.rootPath, $0) }
        }

        while let folder = pending.popLast() {
            try Task.checkCancellation()
            guard let items = try? await files.list(folder, on: deviceID) else {
                continue
            }
            for item in items where !item.isHidden {
                if item.isDirectory {
                    pending.append(item.path)
                    continue
                }
                if FileCategory(item).isMedia, !imported.contains(Self.ledgerKey(item.path, size: item.size)) {
                    found.append(item)
                }
            }
        }
        return found.sorted { $0.modified > $1.modified }
    }

    /// Records imported files so the next scan skips them.
    public func markImported(_ items: [RemoteItem], deviceID: String) {
        var keys = ledger(for: deviceID)
        keys.formUnion(items.map { Self.ledgerKey($0.path, size: $0.size) })
        try? FileManager.default.createDirectory(at: ledgerFolder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(keys).write(to: ledgerURL(deviceID), options: .atomic)
    }

    /// "<Year>/<Month>" subfolder, e.g. "2026/11", for date-organized imports.
    public static func datedSubfolder(for item: RemoteItem) -> String {
        let components = Calendar.current.dateComponents([.year, .month], from: item.modified)
        return String(format: "%04d/%02d", components.year ?? 0, components.month ?? 0)
    }

    private func ledger(for deviceID: String) -> Set<String> {
        guard let data = try? Data(contentsOf: ledgerURL(deviceID)) else {
            return []
        }
        return (try? JSONDecoder().decode(Set<String>.self, from: data)) ?? []
    }

    private func ledgerURL(_ deviceID: String) -> URL {
        let safe = deviceID.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return ledgerFolder.appending(path: "\(safe).json")
    }

    private static func ledgerKey(_ path: String, size: UInt64) -> String {
        "\(path)|\(size)"
    }
}
