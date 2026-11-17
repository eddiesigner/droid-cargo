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

/// How the first-launch Platform Tools setup behaves.
public enum ToolsSetupMode: Sendable {
    case normal
    /// Pretends adb is missing and fakes the install: nothing is downloaded
    /// or written. For previewing the welcome screen on a Mac that has adb.
    case simulated
}

/// Progress of the one-click Platform Tools install.
public enum ToolsInstallState: Equatable, Sendable {
    case idle
    case downloading(fraction: Double)
    case unpacking
    case failed(String)
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

    public static let platformToolsTermsURL = PlatformToolsInstaller.termsURL
    /// Smallest progress change worth a redraw.
    private static let progressStep = 0.01
    /// Simulated install: 50 steps × 60 ms of "download", then 0.8 s "unpacking".
    private static let simulatedSteps = 50
    private static let simulatedStepDelay: Duration = .milliseconds(60)
    private static let simulatedUnpackDelay: Duration = .milliseconds(800)

    private let launcher: ADBServerLauncher?
    private let installer = PlatformToolsInstaller()
    private let setupMode: ToolsSetupMode

    public init(customADBPath: @escaping @Sendable () -> String?, setupMode: ToolsSetupMode = .normal) {
        // Simulation ignores every existing adb so the install screen shows.
        let scope: ADBSearchScope = setupMode == .simulated ? .appInstallOnly : .everywhere
        let launcher = ADBServerLauncher(customPath: customADBPath, installer: installer, scope: scope)
        self.launcher = launcher
        self.setupMode = setupMode
        transports = [ADBTransport(client: ADBClient(launcher: launcher))]
        adbURL = setupMode == .simulated ? nil : launcher.locate()
    }

    /// For previews and tests.
    public init(transports: [any DeviceTransport]) {
        self.transports = transports
        launcher = nil
        setupMode = .normal
        adbURL = URL(filePath: "/usr/bin/true")
    }

    /// The adb in use. Stored, not computed: reading the disk on every redraw would stall the UI.
    public private(set) var adbURL: URL?
    public var isADBInstalled: Bool { adbURL != nil }
    public private(set) var toolsInstall: ToolsInstallState = .idle

    /// Re-checks for adb, e.g. after the user picks its location.
    public func refreshToolsAvailability() {
        guard let launcher else {
            return
        }
        let found = launcher.locate()
        if found != adbURL {
            adbURL = found
        }
    }

    /// Downloads Platform Tools from Google. Device tracking retries every
    /// second, so phones appear without a relaunch.
    public func installPlatformTools() async {
        switch toolsInstall {
        case .downloading, .unpacking:
            return
        case .idle, .failed:
            break
        }

        toolsInstall = .downloading(fraction: 0)
        if setupMode == .simulated {
            await simulateInstall()
            return
        }
        do {
            try await installer.install { [weak self] stage in
                Task { @MainActor in self?.apply(stage) }
            }
            toolsInstall = .idle
            refreshToolsAvailability()
        } catch {
            toolsInstall = .failed(error.localizedDescription)
        }
    }

    /// Walks through the same states as a real install, then reports adb at
    /// the path a real install would use.
    private func simulateInstall() async {
        for step in 1...Self.simulatedSteps {
            try? await Task.sleep(for: Self.simulatedStepDelay)
            apply(.downloading(fraction: Double(step) / Double(Self.simulatedSteps)))
        }
        apply(.unpacking)
        try? await Task.sleep(for: Self.simulatedUnpackDelay)
        toolsInstall = .idle
        adbURL = installer.adbURL
    }

    /// Ignores late or tiny updates so the UI redraws only when it shows something new.
    private func apply(_ stage: PlatformToolsInstaller.Stage) {
        switch (toolsInstall, stage) {
        case (.downloading(let old), .downloading(let new)) where new - old >= Self.progressStep:
            toolsInstall = .downloading(fraction: new)
        case (.downloading, .unpacking):
            toolsInstall = .unpacking
        default:
            break
        }
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
        // Assigning an equal value still notifies observers and redraws every window.
        if unique != devices {
            devices = unique
        }
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
