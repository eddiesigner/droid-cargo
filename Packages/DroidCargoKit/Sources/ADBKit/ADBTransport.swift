import DeviceKit
import Foundation
import Synchronization

/// Device discovery and sessions over USB debugging (adb).
public final class ADBTransport: DeviceTransport {
    public let kind: TransportKind = .adb

    /// Wait before re-attaching to the adb server after it drops.
    private static let reconnectDelay: Duration = .seconds(1)
    private static let featureListV2 = "ls_v2"
    private static let featureStatV2 = "stat_v2"

    private let client: ADBClient
    /// Marketing names fetched once per serial ("Galaxy S23" instead of "SM S911B").
    private let names = Mutex<[String: String]>([:])

    public init(client: ADBClient) {
        self.client = client
    }

    public func devices() -> AsyncStream<[Device]> {
        AsyncStream { continuation in
            let task = Task { [client] in
                // Keep tracking across adb server restarts and cable unplugs.
                while !Task.isCancelled {
                    do {
                        for try await infos in client.trackDevices() {
                            continuation.yield(await self.makeDevices(infos))
                        }
                    } catch {
                        continuation.yield([])
                    }
                    try? await Task.sleep(for: Self.reconnectDelay)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeDevices(_ infos: [ADBDeviceInfo]) async -> [Device] {
        var devices: [Device] = []
        for info in infos {
            let state = info.deviceState
            let name = state == .online ? await displayName(info) : info.model
            devices.append(Device(id: info.serial, name: name, model: info.model, state: state, transport: .adb))
        }
        return devices
    }

    private func displayName(_ info: ADBDeviceInfo) async -> String {
        if let cached = names.withLock({ $0[info.serial] }) {
            return cached
        }
        let output = try? await client.shell("getprop ro.product.marketname; getprop ro.product.model", serial: info.serial)
        let name = output?
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? info.model
        names.withLock { $0[info.serial] = name }
        return name
    }

    public func openSession(_ device: Device) async throws -> any DeviceSession {
        let features = try await client.features(serial: device.id)
        let useV2 = features.contains(Self.featureListV2) && features.contains(Self.featureStatV2)
        return ADBDeviceSession(device: device, client: client, useV2: useV2)
    }
}

/// File operations on one device. Each operation uses its own sync connection,
/// so browsing stays responsive while transfers run.
final class ADBDeviceSession: DeviceSession {
    private static let storageRoot = "/storage"
    private static let primaryStorage = "/storage/emulated/0"
    private static let ignoredStorageNames: Set<String> = ["self", "emulated"]
    private static let kilobyte: UInt64 = 1024
    private static let mediaScanBatch = 40
    private static let exitMarker = "__droidcargo_rc="

    let device: Device
    private let client: ADBClient
    private let useV2: Bool

    init(device: Device, client: ADBClient, useV2: Bool) {
        self.device = device
        self.client = client
        self.useV2 = useV2
    }

    private func withSync<T>(_ body: (SyncClient) async throws -> T) async throws -> T {
        let stream = try await client.open("sync:", serial: device.id)
        let sync = SyncClient(stream: stream, useV2: useV2)
        defer { sync.close() }
        return try await body(sync)
    }

    // MARK: Storage

    func storages() async throws -> [Storage] {
        let entries = try await withSync { try await $0.list(Self.storageRoot) }
        let removable = entries
            .filter { !Self.ignoredStorageNames.contains($0.name) && ($0.isDirectory || $0.isSymlink) }
            .map { RemotePath.join(Self.storageRoot, $0.name) }
        let roots = [Self.primaryStorage] + removable

        let quoted = roots.map(ADBWire.shellQuote).joined(separator: " ")
        let output = try await client.shell("df -k \(quoted)", serial: device.id)
        let capacities = Self.parseDF(output)

        return roots.enumerated().map { index, root in
            let capacity = index < capacities.count ? capacities[index] : (0, 0)
            let isPrimary = root == Self.primaryStorage
            return Storage(
                name: isPrimary ? String(localized: "Internal Storage") : String(localized: "SD Card"),
                rootPath: root,
                kind: isPrimary ? .internalStorage : .removable,
                totalBytes: capacity.0,
                freeBytes: capacity.1
            )
        }
    }

    /// Parses `df -k` into (total, available) bytes per data line, in order.
    static func parseDF(_ output: String) -> [(UInt64, UInt64)] {
        output
            .split(separator: "\n")
            .dropFirst()
            .compactMap { line in
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.count >= 4, let total = UInt64(fields[1]), let free = UInt64(fields[3]) else {
                    return nil
                }
                return (total * kilobyte, free * kilobyte)
            }
    }

    // MARK: Browsing

    func list(_ directory: String) async throws -> [RemoteItem] {
        try await withSync { sync in
            let entries = try await sync.list(directory)
            var items: [RemoteItem] = []
            items.reserveCapacity(entries.count)

            for entry in entries {
                let path = RemotePath.join(directory, entry.name)
                var resolved = entry
                if entry.isSymlink {
                    guard let target = try await sync.stat(path) else {
                        continue
                    }
                    resolved = target
                }
                items.append(RemoteItem(
                    path: path,
                    name: entry.name,
                    kind: resolved.isDirectory ? .directory : .file,
                    size: resolved.isDirectory ? 0 : resolved.size,
                    modified: resolved.modified
                ))
            }
            return items
        }
    }

    func stat(_ path: String) async throws -> RemoteItem? {
        guard let entry = try await withSync({ try await $0.stat(path) }) else {
            return nil
        }
        return RemoteItem(
            path: path,
            name: RemotePath.name(path),
            kind: entry.isDirectory ? .directory : .file,
            size: entry.isDirectory ? 0 : entry.size,
            modified: entry.modified
        )
    }

    // MARK: Transfers

    func download(_ remotePath: String, to localURL: URL, control: TransferControl, progress: ByteProgress) async throws {
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: localURL)
        defer { try? handle.close() }
        try await withSync { try await $0.receive(remotePath, into: handle, control: control, progress: progress) }
    }

    func upload(_ localURL: URL, to remotePath: String, modified: Date, control: TransferControl, progress: ByteProgress) async throws {
        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }
        try await withSync {
            try await $0.send(from: handle, to: remotePath, mode: FileMode.defaultFile, modified: modified, control: control, progress: progress)
        }
    }

    // MARK: File operations

    func makeDirectory(_ path: String) async throws {
        try await run("mkdir -p \(ADBWire.shellQuote(path))")
    }

    func move(_ source: String, to destination: String) async throws {
        try await run("mv -f \(ADBWire.shellQuote(source)) \(ADBWire.shellQuote(destination))")
    }

    func remove(_ path: String) async throws {
        try await run("rm -rf \(ADBWire.shellQuote(path))")
    }

    func notifyMediaScanner(_ paths: [String]) async {
        for start in stride(from: 0, to: paths.count, by: Self.mediaScanBatch) {
            let batch = paths[start..<min(start + Self.mediaScanBatch, paths.count)]
            let commands = batch.map {
                "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d \(ADBWire.shellQuote("file://" + $0)) >/dev/null 2>&1"
            }
            _ = try? await client.shell(commands.joined(separator: "; "), serial: device.id)
        }
    }

    /// Runs a command and throws its output when the exit code is non-zero.
    private func run(_ command: String) async throws {
        let output = try await client.shell("\(command) 2>&1; echo \(Self.exitMarker)$?", serial: device.id)
        guard let range = output.range(of: Self.exitMarker, options: .backwards) else {
            throw DeviceError.protocolViolation("missing exit code")
        }
        let code = output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        if code == "0" {
            return
        }
        let message = output[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        throw ADBWire.mapFailure(message)
    }
}
