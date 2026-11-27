import AppKit
import CargoServices
import Foundation
import Observation
import UserNotifications

/// A name clash waiting for the user's answer.
struct ConflictPrompt: Identifiable {
    let id = UUID()
    let conflict: TransferConflict
    let respond: (ConflictResolution, ConflictScope) -> Void
}

/// Phone items waiting to be pasted: moved if cut, copied if copied.
struct PhoneClipboard {
    let deviceID: String
    let paths: [String]
    let mode: PlaceMode
}

/// App-wide state shared by every window. Views reach services only through here.
@Observable
final class AppModel {
    let settings: AppSettings
    let devices: DeviceService
    let files: FileService
    let transfers: TransferService
    let thumbnails: ThumbnailService
    let previews: PreviewService
    let photoImport: PhotoImportService

    /// Storages per device serial, refreshed when a phone connects.
    private(set) var storages: [String: [Storage]] = [:]
    private(set) var storageErrors: [String: String] = [:]
    var conflictPrompt: ConflictPrompt?
    var isTransfersPopoverShown = false
    /// Items cut (⌘X) or copied (⌘C), waiting for ⌘V in a folder of the same phone.
    var clipboard: PhoneClipboard?

    init() {
        let settings = AppSettings()
        self.settings = settings
        let devices = DeviceService(customADBPath: {
            let path = UserDefaults.standard.string(forKey: "customADBPath") ?? ""
            return path.isEmpty ? nil : path
        }, setupMode: Self.toolsSetupMode)
        self.devices = devices
        files = FileService(devices: devices)
        transfers = TransferService(devices: devices)
        thumbnails = ThumbnailService(devices: devices)
        previews = PreviewService(devices: devices)
        photoImport = PhotoImportService(files: files)

        transfers.onJobFinished = { [weak self] job in self?.jobFinished(job) }
        devices.start()
        observeDevices()
    }

    // MARK: Platform Tools

    /// Development aid: `open DroidCargo.app --args -simulateMissingTools YES`
    /// shows the first-launch install screen and fakes the install.
    private static var toolsSetupMode: ToolsSetupMode {
        UserDefaults.standard.bool(forKey: "simulateMissingTools") ? .simulated : .normal
    }

    func installPlatformTools() {
        Task { await devices.installPlatformTools() }
    }

    /// Uses an adb the user already has somewhere unusual.
    func useADB(at url: URL) {
        settings.customADBPath = url.path
        devices.refreshToolsAvailability()
    }

    // MARK: Devices

    var onlineDevices: [Device] {
        devices.devices.filter { $0.state == .online }
    }

    /// Loads storages whenever the device list changes.
    private func observeDevices() {
        withObservationTracking {
            _ = devices.devices
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshStorages()
                self?.observeDevices()
            }
        }
    }

    func refreshStorages() {
        let online = Set(onlineDevices.map(\.id))
        let kept = storages.filter { online.contains($0.key) }
        if kept.count != storages.count {
            storages = kept
        }
        for id in online where storages[id] == nil {
            Task { await loadStorages(id) }
        }
    }

    func loadStorages(_ deviceID: String) async {
        do {
            let loaded = try await files.storages(on: deviceID)
            if storages[deviceID] != loaded {
                storages[deviceID] = loaded
            }
            if storageErrors[deviceID] != nil {
                storageErrors[deviceID] = nil
            }
        } catch {
            storageErrors[deviceID] = error.localizedDescription
        }
    }

    // MARK: Transfers

    @discardableResult
    func download(_ items: [RemoteItem], from device: Device, to folder: URL? = nil) -> TransferJob {
        let destination = folder ?? settings.downloadFolder
        isTransfersPopoverShown = true
        return transfers.download(
            items.map { (item: $0, folder: destination) },
            from: device,
            options: settings.transferOptions,
            onConflict: askAboutConflict
        )
    }

    @discardableResult
    func upload(_ urls: [URL], to remoteFolder: String, on device: Device) -> TransferJob {
        isTransfersPopoverShown = true
        return transfers.upload(urls, to: remoteFolder, on: device, options: settings.transferOptions, onConflict: askAboutConflict)
    }

    /// Downloads new camera items, optionally into Year/Month folders, and remembers them.
    func importPhotos(_ items: [RemoteItem], from device: Device, to base: URL) {
        let organization = settings.photoOrganization
        let requests = items.map { item in
            let folder = organization == .byMonth
                ? base.appending(path: PhotoImportService.datedSubfolder(for: item), directoryHint: .isDirectory)
                : base
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return (item: item, folder: folder)
        }
        isTransfersPopoverShown = true
        let job = transfers.download(requests, from: device, options: settings.transferOptions, onConflict: askAboutConflict)

        Task {
            await job.finished()
            let done = Set(job.downloadedRemotePaths)
            photoImport.markImported(items.filter { done.contains($0.path) }, deviceID: device.id)
        }
    }

    /// Moves or copies items between folders on one phone. Returns their new paths.
    func place(_ paths: [String], into folder: String, on deviceID: String, mode: PlaceMode) async throws -> [String] {
        try await files.place(paths, into: folder, on: deviceID, mode: mode, options: settings.transferOptions, onConflict: askAboutConflict)
    }

    /// Downloads into a temp folder for drag-and-drop to Finder. Returns the local copy.
    func exportForDrag(_ item: RemoteItem, from device: Device) async throws -> URL {
        let folder = URL.temporaryDirectory.appending(path: "DragOut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let job = transfers.download([(item: item, folder: folder)], from: device, options: settings.transferOptions, onConflict: askAboutConflict)
        await job.finished()
        let result = folder.appending(path: item.name)
        guard FileManager.default.fileExists(atPath: result.path) else {
            throw DeviceError.remote(job.failures.first?.message ?? String(localized: "The file could not be copied."))
        }
        return result
    }

    private func askAboutConflict(_ conflict: TransferConflict) async -> (ConflictResolution, ConflictScope) {
        await withCheckedContinuation { continuation in
            conflictPrompt = ConflictPrompt(conflict: conflict) { [weak self] resolution, scope in
                self?.conflictPrompt = nil
                continuation.resume(returning: (resolution, scope))
            }
        }
    }

    private func jobFinished(_ job: TransferJob) {
        if job.direction == .toDevice {
            Task { await loadStorages(job.deviceID) }
        }
        if job.direction == .toMac, job.phase == .completed, settings.revealAfterDownload, let folder = job.localFolder {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
        notify(job)
    }

    // MARK: Notifications

    func requestNotificationPermission() {
        guard settings.notifyWhenDone else {
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Only when the app is in the background; in front, the progress UI already says it.
    private func notify(_ job: TransferJob) {
        guard settings.notifyWhenDone, !NSApp.isActive, job.phase != .cancelled else {
            return
        }
        let content = UNMutableNotificationContent()
        switch job.phase {
        case .completed where job.failures.isEmpty:
            content.title = job.direction == .toMac ? String(localized: "Download complete") : String(localized: "Upload complete")
            content.body = String(localized: "\(job.completedFiles) files · \(job.deviceName)")
        default:
            content.title = String(localized: "Transfer finished with problems")
            content.body = String(localized: "\(job.failures.count) files could not be copied.")
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: job.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: Language

    /// macOS applies an app's language only at launch, so start a fresh copy and quit.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: Caches

    func clearCaches() async {
        await thumbnails.clearCache()
        previews.clearCache()
    }
}
