import Foundation

/// How the Mac talks to the phone.
public enum TransportKind: String, Sendable, Codable {
    case adb
    case mtp
}

public enum DeviceState: Sendable, Hashable {
    case online
    /// The phone is waiting for the user to accept the "Allow USB debugging?" prompt.
    case unauthorized
    case offline
    case unsupported(String)
}

public struct Device: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var model: String
    public var state: DeviceState
    public var transport: TransportKind

    public init(id: String, name: String, model: String, state: DeviceState, transport: TransportKind) {
        self.id = id
        self.name = name
        self.model = model
        self.state = state
        self.transport = transport
    }
}

public enum StorageKind: Sendable, Hashable {
    case internalStorage
    case removable
}

public struct Storage: Identifiable, Hashable, Sendable {
    public var id: String { rootPath }
    public let name: String
    public let rootPath: String
    public let kind: StorageKind
    public let totalBytes: UInt64
    public let freeBytes: UInt64

    public init(name: String, rootPath: String, kind: StorageKind, totalBytes: UInt64, freeBytes: UInt64) {
        self.name = name
        self.rootPath = rootPath
        self.kind = kind
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
    }

    public var usedBytes: UInt64 { totalBytes > freeBytes ? totalBytes - freeBytes : 0 }
}

public enum RemoteItemKind: Sendable, Hashable {
    case file
    case directory
}

public struct RemoteItem: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let kind: RemoteItemKind
    public let size: UInt64
    public let modified: Date

    public init(path: String, name: String, kind: RemoteItemKind, size: UInt64, modified: Date) {
        self.path = path
        self.name = name
        self.kind = kind
        self.size = size
        self.modified = modified
    }

    public var isDirectory: Bool { kind == .directory }
    public var isHidden: Bool { name.hasPrefix(".") }
    public var fileExtension: String { (name as NSString).pathExtension.lowercased() }
}

/// POSIX-style path helpers for device paths.
public enum RemotePath {
    public static func join(_ directory: String, _ name: String) -> String {
        if directory.hasSuffix("/") {
            return directory + name
        }
        return directory + "/" + name
    }

    public static func parent(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    public static func name(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
