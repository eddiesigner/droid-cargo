import DeviceKit
import Foundation

/// Browsing and simple file operations on a phone.
@MainActor
public final class FileService {
    private let devices: DeviceService

    public init(devices: DeviceService) {
        self.devices = devices
    }

    public func storages(on deviceID: String) async throws -> [Storage] {
        try await withSession(deviceID) { try await $0.storages() }
    }

    public func list(_ directory: String, on deviceID: String) async throws -> [RemoteItem] {
        try await withSession(deviceID) { try await $0.list(directory) }
    }

    public func makeFolder(named name: String, in directory: String, on deviceID: String) async throws -> String {
        let path = RemotePath.join(directory, name)
        try await withSession(deviceID) { try await $0.makeDirectory(path) }
        return path
    }

    public func rename(_ path: String, to newName: String, on deviceID: String) async throws {
        let destination = RemotePath.join(RemotePath.parent(path), newName)
        try await withSession(deviceID) { try await $0.move(path, to: destination) }
    }

    public func delete(_ paths: [String], on deviceID: String) async throws {
        try await withSession(deviceID) { session in
            for path in paths {
                try await session.remove(path)
            }
        }
    }

    /// Runs `body`, reconnecting once if the session went stale.
    private func withSession<T: Sendable>(_ deviceID: String, _ body: (any DeviceSession) async throws -> T) async throws -> T {
        let session = try await devices.session(for: deviceID)
        do {
            return try await body(session)
        } catch let error as DeviceError where error.isTransient {
            devices.invalidate(deviceID)
            return try await body(try await devices.session(for: deviceID))
        }
    }
}
