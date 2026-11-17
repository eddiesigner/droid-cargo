import DeviceKit
import Foundation

/// A device line from "host:track-devices-l", e.g.
/// `R58N1234  device product:o1sxeea model:SM_G991B device:o1s transport_id:3`
struct ADBDeviceInfo: Equatable, Sendable {
    let serial: String
    let state: String
    let model: String

    static func parse(_ text: String) -> [ADBDeviceInfo] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2 else {
                return nil
            }
            let model = fields
                .first { $0.hasPrefix("model:") }
                .map { String($0.dropFirst("model:".count)).replacingOccurrences(of: "_", with: " ") }
            return ADBDeviceInfo(serial: fields[0], state: fields[1], model: model ?? fields[0])
        }
    }

    var deviceState: DeviceState {
        switch state {
        case "device":
            return .online
        case "unauthorized", "authorizing":
            return .unauthorized
        case "offline", "connecting":
            return .offline
        default:
            return .unsupported(state)
        }
    }
}

/// Talks to the local adb server: device tracking, opening device services.
public final class ADBClient: Sendable {
    public static let defaultPort: UInt16 = 5037

    private let port: UInt16
    private let launcher: ADBServerLauncher

    public init(port: UInt16 = ADBClient.defaultPort, launcher: ADBServerLauncher) {
        self.port = port
        self.launcher = launcher
    }

    /// Opens a socket to the server, starting the server once if it is not running.
    func connect() async throws -> ADBStream {
        do {
            return try await openSocket()
        } catch {
            try await launcher.startServer()
            return try await openSocket()
        }
    }

    private func openSocket() async throws -> ADBStream {
        let socket = ADBSocket(port: port)
        try await socket.open()
        return socket
    }

    /// Emits the device list on every change until cancelled or the server goes away.
    func trackDevices() -> AsyncThrowingStream<[ADBDeviceInfo], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let stream = try await connect()
                    defer { stream.close() }
                    try await stream.write(ADBWire.hostRequest("host:track-devices-l"))
                    try await ADBWire.readStatus(stream)
                    while !Task.isCancelled {
                        let text = try await ADBWire.readHexString(stream)
                        continuation.yield(ADBDeviceInfo.parse(text))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func features(serial: String) async throws -> Set<String> {
        let stream = try await connect()
        defer { stream.close() }
        try await stream.write(ADBWire.hostRequest("host-serial:\(serial):features"))
        try await ADBWire.readStatus(stream)
        let text = try await ADBWire.readHexString(stream)
        return Set(text.split(separator: ",").map(String.init))
    }

    /// Connects to `service` (e.g. "sync:", "shell:ls") on one device.
    func open(_ service: String, serial: String) async throws -> ADBStream {
        let stream = try await connect()
        do {
            try await stream.write(ADBWire.hostRequest("host:transport:\(serial)"))
            try await ADBWire.readStatus(stream)
            try await stream.write(ADBWire.hostRequest(service))
            try await ADBWire.readStatus(stream)
            return stream
        } catch {
            stream.close()
            throw error
        }
    }

    /// Runs a shell command and returns its combined output.
    func shell(_ command: String, serial: String) async throws -> String {
        let stream = try await open("shell:\(command)", serial: serial)
        defer { stream.close() }
        return String(decoding: try await stream.readToEnd(), as: UTF8.self)
    }
}
