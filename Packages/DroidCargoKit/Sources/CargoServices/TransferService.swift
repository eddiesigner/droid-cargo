import DeviceKit
import Foundation
import Observation

/// Queue of transfers between the Mac and phones.
@MainActor
@Observable
public final class TransferService {
    /// UI refresh rate for progress and speed.
    private static let sampleInterval: Duration = .milliseconds(250)

    public private(set) var jobs: [TransferJob] = []
    /// Called once per job when it completes, fails or is cancelled.
    @ObservationIgnored public var onJobFinished: ((TransferJob) -> Void)?

    private let devices: DeviceService
    private var sleepAssertion: NSObjectProtocol?

    public init(devices: DeviceService) {
        self.devices = devices
    }

    public var activeJobs: [TransferJob] {
        jobs.filter { !$0.phase.isFinished }
    }

    /// Overall progress across running jobs, for the toolbar indicator.
    public var overallFraction: Double? {
        let active = activeJobs
        let total = active.reduce(UInt64(0)) { $0 + $1.totalBytes }
        guard !active.isEmpty, total > 0 else {
            return active.isEmpty ? nil : 0
        }
        let done = active.reduce(UInt64(0)) { $0 + $1.transferredBytes }
        return Double(done) / Double(total)
    }

    // MARK: Starting jobs

    /// Copies phone items into Mac folders. Each item names its own destination folder.
    @discardableResult
    public func download(
        _ requests: [(item: RemoteItem, folder: URL)],
        from device: Device,
        options: TransferOptions,
        onConflict: @escaping ConflictHandler
    ) -> TransferJob {
        let title = Self.title(for: requests.map(\.item.name), direction: .toMac)
        let job = TransferJob(direction: .toMac, title: title, device: device, localFolder: requests.first?.folder)
        start(job, deviceID: device.id, options: options, onConflict: onConflict) { session, found in
            try await TransferEngine.planDownload(requests.map { ($0.item, $0.folder) }, session: session, onFound: found)
        }
        return job
    }

    /// Copies Mac files and folders into a phone folder.
    @discardableResult
    public func upload(
        _ urls: [URL],
        to remoteFolder: String,
        on device: Device,
        options: TransferOptions,
        onConflict: @escaping ConflictHandler
    ) -> TransferJob {
        let title = Self.title(for: urls.map(\.lastPathComponent), direction: .toDevice)
        let job = TransferJob(direction: .toDevice, title: title, device: device, localFolder: nil)
        start(job, deviceID: device.id, options: options, onConflict: onConflict) { session, found in
            try await TransferEngine.planUpload(urls, to: remoteFolder, session: session, onFound: found)
        }
        return job
    }

    private func start(
        _ job: TransferJob,
        deviceID: String,
        options: TransferOptions,
        onConflict: @escaping ConflictHandler,
        plan: @escaping @Sendable (any DeviceSession, @escaping @Sendable (Int, UInt64) async -> Void) async throws -> [PlannedFile]
    ) {
        jobs.insert(job, at: 0)
        updateSleepAssertion()

        let devices = devices
        let sessions = SessionSource(
            get: { policy in try await devices.session(for: deviceID, reconnect: policy) },
            invalidate: { await devices.invalidate(deviceID) }
        )
        let engine = TransferEngine(
            sessions: sessions,
            options: options,
            control: job.control,
            counter: job.counter,
            conflicts: ConflictArbiter(handler: onConflict),
            onFileStarted: { [weak job] name in await MainActor.run { job?.currentItemName = name } },
            onFileFinished: { [weak job] outcome in await job?.record(outcome) }
        )

        job.task = Task { [weak self] in
            let sampler = Task {
                while !Task.isCancelled {
                    job.sample()
                    try? await Task.sleep(for: Self.sampleInterval)
                }
            }
            defer { sampler.cancel() }

            do {
                // 1. Count everything first so progress is accurate from the start.
                let session = try await sessions.get(.immediate)
                let files = try await plan(session) { count, bytes in
                    await job.updatePlan(files: count, bytes: bytes)
                }
                job.phase = job.control.runState == .paused ? .paused : .running

                // 2. Move the files.
                try await engine.run(files)

                // 3. Let Gallery and other apps see new media, then drop the adb
                //    shell as their "creator" (the index entry must exist first).
                if job.direction == .toDevice, let session = try? await sessions.get(.immediate) {
                    if options.scanMediaAfterUpload {
                        await session.notifyMediaScanner(job.uploadedRemotePaths)
                    }
                    await session.releaseOwnership(job.uploadedRemotePaths)
                }
                job.phase = job.failures.isEmpty || job.completedFiles > 0 ? .completed : .failed(job.failures.first?.message ?? "")
            } catch is CancellationError {
                job.phase = .cancelled
            } catch {
                job.phase = .failed(error.localizedDescription)
            }

            job.sample()
            job.bytesPerSecond = 0
            job.currentItemName = nil
            self?.finish(job)
        }
    }

    private func finish(_ job: TransferJob) {
        updateSleepAssertion()
        onJobFinished?(job)
    }

    // MARK: Controls

    public func pause(_ job: TransferJob) {
        guard job.phase == .running || job.phase == .preparing else {
            return
        }
        job.control.set(.paused)
        job.phase = .paused
    }

    public func resume(_ job: TransferJob) {
        guard job.phase == .paused else {
            return
        }
        job.control.set(.running)
        job.phase = job.totalFiles == 0 ? .preparing : .running
    }

    public func cancel(_ job: TransferJob) {
        job.control.set(.running)
        job.task?.cancel()
    }

    public func clearFinished() {
        jobs.removeAll { $0.phase.isFinished }
    }

    /// Keeps the Mac awake while anything is transferring.
    private func updateSleepAssertion() {
        let busy = !activeJobs.isEmpty
        if busy, sleepAssertion == nil {
            sleepAssertion = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Transferring files"
            )
        }
        if !busy, let assertion = sleepAssertion {
            ProcessInfo.processInfo.endActivity(assertion)
            sleepAssertion = nil
        }
    }

    private static func title(for names: [String], direction: TransferDirection) -> String {
        guard let first = names.first else {
            return ""
        }
        return names.count == 1 ? first : String(localized: "\(first) and \(names.count - 1) more")
    }
}

extension TransferJob {
    func updatePlan(files: Int, bytes: UInt64) {
        totalFiles = files
        totalBytes = bytes
    }

    func record(_ outcome: FileOutcome) {
        switch outcome {
        case .transferred(let file, let finalPath):
            completedFiles += 1
            if case .download(let remotePath, _, _, _) = file {
                downloadedRemotePaths.append(remotePath)
            } else {
                uploadedRemotePaths.append(finalPath)
            }
        case .skipped(let file):
            skippedFiles += 1
            totalBytes -= min(totalBytes, file.size)
        case .failed(let file, let message):
            failures.append(TransferFailure(name: file.name, message: message))
            totalBytes -= min(totalBytes, file.size)
        }
    }
}
