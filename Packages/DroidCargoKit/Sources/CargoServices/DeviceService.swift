@_exported import DeviceKit
import ADBKit
import Foundation
import Observation

enum ReconnectPolicy: Sendable {
    /// Fail right away when the phone is not online.
    case immediate
    /// Wait up to `DeviceService.reconnectTimeout` for it to come back.
    case waitForDevice
}

/// Tracks connected phones and hands out sessions to the other services.
@MainActor
@Observable
public final class DeviceService {
    /// How long a retry waits for an unplugged phone to come back.
    public static let reconnectTimeout: Duration = .seconds(20)
    private static let reconnectPoll: Duration = .milliseconds(250)

    public private(set) var devices: [Device] = []
    public private(set) var hasStarted = false

    private let transports: [any DeviceTransport]
    private var sessions: [String: any DeviceSession] = [:]
    private var tracking: [Task<Void, Never>] = []

    public init(customADBPath: @escaping @Sendable () -> String?) {
        let launcher = ADBServerLauncher(customPath: customADBPath)
        transports = [ADBTransport(client: ADBClient(launcher: launcher))]
    }

    /// For previews and tests.
    public init(transports: [any DeviceTransport]) {
        self.transports = transports
    }

    public var isADBInstalled: Bool {
        ADBServerLauncher().locate() != nil
    }

    public func start() {
        guard !hasStarted else {
            return
        }
        hasStarted = true

        // Merge the lists of every transport, keeping one entry per serial.
        var perTransport: [TransportKind: [Device]] = [:]
        for transport in transports {
            let task = Task { [weak self] in
                for await list in transport.devices() {
                    guard let self else {
                        return
                    }
                    perTransport[transport.kind] = list
                    self.apply(perTransport.values.flatMap { $0 })
                }
            }
            tracking.append(task)
        }
    }

    private func apply(_ merged: [Device]) {
        var seen = Set<String>()
        let unique = merged.filter { seen.insert($0.id).inserted }

        // Drop sessions of devices that left or went offline.
        let online = Set(unique.filter { $0.state == .online }.map(\.id))
        sessions = sessions.filter { online.contains($0.key) }
        devices = unique
    }

    public func device(id: String) -> Device? {
        devices.first { $0.id == id }
    }

    /// Returns a session, optionally waiting for the phone to reconnect if it is briefly gone.
    func session(for deviceID: String, reconnect: ReconnectPolicy = .immediate) async throws -> any DeviceSession {
        if let session = sessions[deviceID] {
            return session
        }

        let deadline = ContinuousClock.now + (reconnect == .waitForDevice ? Self.reconnectTimeout : .zero)
        while true {
            if let device = device(id: deviceID), device.state == .online {
                let session = try await transport(for: device).openSession(device)
                sessions[deviceID] = session
                return session
            }
            guard ContinuousClock.now < deadline else {
                throw DeviceError.deviceDisconnected
            }
            try await Task.sleep(for: Self.reconnectPoll)
        }
    }

    /// Forgets a session so the next request reconnects from scratch.
    func invalidate(_ deviceID: String) {
        sessions[deviceID] = nil
    }

    private func transport(for device: Device) throws -> any DeviceTransport {
        guard let transport = transports.first(where: { $0.kind == device.transport }) else {
            throw DeviceError.transportUnavailable(device.transport.rawValue)
        }
        return transport
    }
}
