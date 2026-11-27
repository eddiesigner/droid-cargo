import Foundation

public enum DeviceError: Error, Sendable, Equatable, LocalizedError {
    case transportUnavailable(String)
    case deviceDisconnected
    case notFound(String)
    case permissionDenied(String)
    case remote(String)
    case protocolViolation(String)

    public var errorDescription: String? {
        switch self {
        case .transportUnavailable(let reason):
            return reason
        case .deviceDisconnected:
            return String(localized: "The device was disconnected.")
        case .notFound(let path):
            return String(localized: "“\(path)” no longer exists on the device.")
        case .permissionDenied(let path):
            return String(localized: "The device denied access to “\(path)”.")
        case .remote(let message):
            return message
        case .protocolViolation(let message):
            return String(localized: "Unexpected response from the device: \(message)")
        }
    }

    /// Errors worth retrying once the device is reachable again.
    public var isTransient: Bool {
        switch self {
        case .deviceDisconnected, .protocolViolation, .transportUnavailable:
            return true
        case .notFound, .permissionDenied, .remote:
            return false
        }
    }
}

/// Called with the number of bytes moved since the previous call.
public typealias ByteProgress = @Sendable (UInt64) -> Void

/// One open connection to one device. All paths are absolute device paths.
public protocol DeviceSession: Sendable {
    var device: Device { get }

    func storages() async throws -> [Storage]
    func list(_ directory: String) async throws -> [RemoteItem]
    func stat(_ path: String) async throws -> RemoteItem?

    /// Reads at most `maxBytes` from the start of a file, e.g. for embedded previews.
    func readPrefix(_ remotePath: String, maxBytes: Int) async throws -> Data
    /// Reads at most `maxBytes` from the end of a file, e.g. a video's index.
    func readSuffix(_ remotePath: String, maxBytes: Int) async throws -> Data

    func download(_ remotePath: String, to localURL: URL, control: TransferControl, progress: ByteProgress) async throws
    func upload(_ localURL: URL, to remotePath: String, modified: Date, control: TransferControl, progress: ByteProgress) async throws

    func makeDirectory(_ path: String) async throws
    func move(_ source: String, to destination: String) async throws
    /// Copies a file or folder (recursively) on the phone, keeping its dates.
    func copy(_ source: String, to destination: String) async throws
    func remove(_ path: String) async throws

    /// Asks the phone to index new files so they show up in Gallery and other apps.
    func notifyMediaScanner(_ paths: [String]) async

    /// Clears the "created by" app the phone recorded for uploaded files, so
    /// they look like files copied over USB rather than by a developer tool.
    func releaseOwnership(_ paths: [String]) async
}

/// Finds devices and opens sessions for one kind of connection.
public protocol DeviceTransport: Sendable {
    var kind: TransportKind { get }

    /// Emits the full device list each time it changes.
    func devices() -> AsyncStream<[Device]>
    func openSession(_ device: Device) async throws -> any DeviceSession
}
