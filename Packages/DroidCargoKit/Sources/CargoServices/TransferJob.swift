import DeviceKit
import Foundation
import Observation
import Synchronization

public enum TransferDirection: Sendable {
    case toMac
    case toDevice
}

public enum TransferPhase: Equatable, Sendable {
    /// Walking folders to count files and bytes.
    case preparing
    case running
    case paused
    case completed
    case failed(String)
    case cancelled

    public var isFinished: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        case .preparing, .running, .paused:
            return false
        }
    }
}

public struct TransferFailure: Identifiable, Sendable {
    public let id = UUID()
    public let name: String
    public let message: String
}

/// Live state of one transfer, observed by the UI.
@MainActor
@Observable
public final class TransferJob: Identifiable {
    /// Weight of the newest sample in the smoothed speed.
    private static let speedSmoothing = 0.25

    public let id = UUID()
    public let direction: TransferDirection
    public let title: String
    public let deviceID: String
    public let deviceName: String
    /// Folder on the Mac, for "Show in Finder" after downloads.
    public let localFolder: URL?
    public let startedAt = Date()

    public internal(set) var phase: TransferPhase = .preparing
    public internal(set) var totalFiles = 0
    public internal(set) var totalBytes: UInt64 = 0
    public internal(set) var completedFiles = 0
    public internal(set) var skippedFiles = 0
    public internal(set) var transferredBytes: UInt64 = 0
    public internal(set) var currentItemName: String?
    public internal(set) var bytesPerSecond: Double = 0
    public internal(set) var failures: [TransferFailure] = []
    /// Remote paths that finished successfully (downloads only).
    public internal(set) var downloadedRemotePaths: [String] = []
    /// Final phone paths of uploaded files, for the media scanner.
    var uploadedRemotePaths: [String] = []

    let control = TransferControl()
    let counter = ByteCounter()
    var task: Task<Void, Never>?
    private var lastSample: (date: Date, bytes: UInt64)?

    init(direction: TransferDirection, title: String, device: Device, localFolder: URL?) {
        self.direction = direction
        self.title = title
        deviceID = device.id
        deviceName = device.name
        self.localFolder = localFolder
    }

    /// Waits until the job completes, fails or is cancelled.
    public func finished() async {
        await task?.value
    }

    public var fractionCompleted: Double {
        guard totalBytes > 0 else {
            return phase == .completed ? 1 : 0
        }
        return min(1, Double(transferredBytes) / Double(totalBytes))
    }

    public var estimatedTimeRemaining: TimeInterval? {
        guard phase == .running, bytesPerSecond > 0, totalBytes > transferredBytes else {
            return nil
        }
        return Double(totalBytes - transferredBytes) / bytesPerSecond
    }

    /// Pulls the byte counter into observable state and updates the speed.
    func sample() {
        let bytes = counter.value
        let now = Date()
        transferredBytes = bytes

        guard phase == .running else {
            bytesPerSecond = 0
            lastSample = (now, bytes)
            return
        }
        defer { lastSample = (now, bytes) }
        guard let last = lastSample else {
            return
        }
        let elapsed = now.timeIntervalSince(last.date)
        guard elapsed > 0, bytes >= last.bytes else {
            return
        }
        let instant = Double(bytes - last.bytes) / elapsed
        bytesPerSecond = bytesPerSecond == 0 ? instant : bytesPerSecond + Self.speedSmoothing * (instant - bytesPerSecond)
    }
}

/// Thread-safe running byte total shared by transfer workers.
final class ByteCounter: Sendable {
    private let bytes = Mutex<UInt64>(0)

    var value: UInt64 { bytes.withLock { $0 } }

    func add(_ amount: UInt64) {
        bytes.withLock { $0 += amount }
    }

    func subtract(_ amount: UInt64) {
        bytes.withLock { $0 -= min($0, amount) }
    }
}
