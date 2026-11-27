import AppKit
import CargoServices
import Foundation
import Synchronization
import Observation

enum SidebarSelection: Hashable {
    case storage(deviceID: String, rootPath: String)
    case favorite(deviceID: String, path: String)

    var deviceID: String {
        switch self {
        case .storage(let id, _), .favorite(let id, _):
            return id
        }
    }

    var path: String {
        switch self {
        case .storage(_, let path), .favorite(_, let path):
            return path
        }
    }
}

enum LoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

/// Navigation and listing state for one window.
/// A file being copied to the Mac so Quick Look can show it.
struct PreviewPreparation: Equatable {
    let name: String
    var fraction: Double
}

/// Running total of bytes reported from the transfer thread.
nonisolated private final class ReceivedBytes: Sendable {
    private let total = Mutex<UInt64>(0)

    func add(_ bytes: UInt64) -> UInt64 {
        total.withLock {
            $0 += bytes
            return $0
        }
    }
}

/// How `load` treats what is already on screen.
enum ReloadStyle {
    /// Entering a folder: clear selection and search, show the cached listing or a spinner.
    case navigate
    /// Same folder again: keep files, selection and search until fresh data arrives.
    case refresh
}

@Observable
final class BrowserModel {
    let app: AppModel

    var sidebarSelection: SidebarSelection? {
        didSet {
            guard let sidebarSelection, sidebarSelection != oldValue else {
                return
            }
            deviceID = sidebarSelection.deviceID
            history = [sidebarSelection.path]
            historyIndex = 0
            Task { await load() }
        }
    }

    private(set) var deviceID: String?
    private(set) var history: [String] = []
    private(set) var historyIndex = 0
    private(set) var items: [RemoteItem] = [] {
        didSet {
            itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            rebuildVisibleItems()
        }
    }
    /// Filtered and sorted, folders first like Finder's "Keep folders on top".
    /// Stored, not computed: sorting thousands of names on every redraw causes lag.
    private(set) var visibleItems: [RemoteItem] = []
    private(set) var state: LoadState = .idle
    var selection = Set<RemoteItem.ID>()
    var searchText = "" {
        didSet {
            if searchText != oldValue {
                rebuildVisibleItems()
            }
        }
    }
    var sortOrder = [KeyPathComparator(\RemoteItem.name, comparator: .localizedStandard)] {
        didSet { rebuildVisibleItems() }
    }
    var isInspectorShown = false
    var isPhotoImportShown = false
    var isNewFolderShown = false
    var renameTarget: RemoteItem?
    var pendingDeletion: [RemoteItem] = []
    var operationError: String?
    /// Local copy shown by Quick Look.
    var previewURL: URL?
    /// Shown once copying a file for Quick Look takes noticeably long.
    private(set) var previewPreparation: PreviewPreparation?
    private var previewTask: Task<Void, Never>?

    /// Listings already seen, shown instantly while a fresh one loads.
    private var cache: [String: [RemoteItem]] = [:]
    private var loadTask: Task<Void, Never>?
    private var itemsByID: [RemoteItem.ID: RemoteItem] = [:]
    private var rebuildTask: Task<Void, Never>?
    private var loadedPath: String?

    init(app: AppModel) {
        self.app = app
        observeHiddenFilesSetting()
    }

    private func observeHiddenFilesSetting() {
        withObservationTracking {
            _ = app.settings.showHiddenFiles
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.rebuildVisibleItems()
                self?.observeHiddenFilesSetting()
            }
        }
    }

    /// Folders below this size are sorted inline so navigation never shows a stale frame.
    private static let inlineSortLimit = 1_500

    /// Filters and sorts; large folders go off the main thread and the newest request wins.
    private func rebuildVisibleItems() {
        rebuildTask?.cancel()
        let items = items
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let showHidden = app.settings.showHiddenFiles
        let sortOrder = sortOrder

        guard items.count > Self.inlineSortLimit else {
            visibleItems = Self.arrange(items, query: query, showHidden: showHidden, sortOrder: sortOrder)
            return
        }
        rebuildTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                Self.arrange(items, query: query, showHidden: showHidden, sortOrder: sortOrder)
            }.value
            guard !Task.isCancelled else {
                return
            }
            visibleItems = result
        }
    }

    nonisolated private static func arrange(
        _ items: [RemoteItem],
        query: String,
        showHidden: Bool,
        sortOrder: [KeyPathComparator<RemoteItem>]
    ) -> [RemoteItem] {
        let filtered = items.filter { item in
            (showHidden || !item.isHidden) && (query.isEmpty || item.name.localizedStandardContains(query))
        }
        let sorted = filtered.sorted(using: sortOrder)
        return sorted.filter(\.isDirectory) + sorted.filter { !$0.isDirectory }
    }

    // MARK: Derived state

    var device: Device? {
        deviceID.flatMap { app.devices.device(id: $0) }
    }

    var currentPath: String? {
        history.indices.contains(historyIndex) ? history[historyIndex] : nil
    }

    var storage: Storage? {
        guard let deviceID, let currentPath else {
            return nil
        }
        return app.storages[deviceID]?
            .filter { currentPath.hasPrefix($0.rootPath) }
            .max { $0.rootPath.count < $1.rootPath.count }
    }

    var selectedItems: [RemoteItem] {
        selection.compactMap { itemsByID[$0] }
    }

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex < history.count - 1 }

    var canGoUp: Bool {
        guard let currentPath, let storage else {
            return false
        }
        return currentPath != storage.rootPath
    }

    /// Path segments from the storage root, for the path bar.
    var breadcrumbs: [(name: String, path: String)] {
        guard let currentPath, let storage else {
            return []
        }
        var crumbs = [(name: storage.name, path: storage.rootPath)]
        let relative = currentPath.dropFirst(storage.rootPath.count).split(separator: "/")
        var path = storage.rootPath
        for part in relative {
            path = RemotePath.join(path, String(part))
            crumbs.append((name: String(part), path: path))
        }
        return crumbs
    }

    // MARK: Navigation

    func open(_ item: RemoteItem) {
        guard item.isDirectory else {
            return
        }
        navigate(to: item.path)
    }

    func navigate(to path: String) {
        guard path != currentPath else {
            return
        }
        history = Array(history.prefix(historyIndex + 1)) + [path]
        historyIndex = history.count - 1
        Task { await load() }
    }

    func goBack() {
        guard canGoBack else {
            return
        }
        historyIndex -= 1
        Task { await load() }
    }

    func goForward() {
        guard canGoForward else {
            return
        }
        historyIndex += 1
        Task { await load() }
    }

    func goUp() {
        guard canGoUp, let currentPath else {
            return
        }
        navigate(to: RemotePath.parent(currentPath))
    }

    /// Shows the cached listing right away, then replaces it with a fresh one.
    /// A refresh keeps what is on screen (files, selection, search) until the
    /// fresh listing arrives, so it never flashes an empty or loading view.
    func load(_ style: ReloadStyle = .navigate) async {
        loadTask?.cancel()
        guard let deviceID, let path = currentPath else {
            return
        }
        if path != loadedPath {
            // Never show the previous folder's items under the new title.
            visibleItems = []
            loadedPath = path
        }
        if style == .navigate {
            selection = []
            searchText = ""
            if let cached = cache[path] {
                items = cached
                state = .loaded
            } else {
                items = []
                state = .loading
            }
        } else if items.isEmpty {
            // Nothing to keep on screen (e.g. Try Again after an error).
            state = .loading
        }

        let task = Task {
            do {
                let fresh = try await app.files.list(path, on: deviceID)
                guard !Task.isCancelled, path == currentPath else {
                    return
                }
                cache[path] = fresh
                items = fresh
                state = .loaded
            } catch {
                guard !Task.isCancelled, path == currentPath else {
                    return
                }
                state = .failed(error.localizedDescription)
            }
        }
        loadTask = task
        await task.value
    }

    func refresh() {
        Task { await load(.refresh) }
    }

    // MARK: File operations

    func makeFolder(named name: String) async throws {
        guard let deviceID, let currentPath else {
            return
        }
        let path = try await app.files.makeFolder(named: name, in: currentPath, on: deviceID)
        await load()
        selection = [path]
    }

    func rename(_ item: RemoteItem, to name: String) async throws {
        guard let deviceID else {
            return
        }
        try await app.files.rename(item.path, to: name, on: deviceID)
        await load()
        selection = [RemotePath.join(RemotePath.parent(item.path), name)]
    }

    func delete(_ items: [RemoteItem]) async throws {
        guard let deviceID else {
            return
        }
        try await app.files.delete(items.map(\.path), on: deviceID)
        await load()
        await app.loadStorages(deviceID)
    }

    func download(_ items: [RemoteItem], to folder: URL? = nil) {
        guard let device, !items.isEmpty else {
            return
        }
        app.download(items, from: device, to: folder)
    }

    func upload(_ urls: [URL], into folder: String? = nil) {
        guard let device, let destination = folder ?? currentPath, !urls.isEmpty else {
            return
        }
        let job = app.upload(urls, to: destination, on: device)
        Task {
            // Show new files as soon as the job ends.
            await job.finished()
            if destination == currentPath {
                refresh()
            }
        }
    }

    // MARK: Panels and previews

    func requestUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Upload")
        panel.message = String(localized: "Choose files or folders to copy to \(device?.name ?? "the phone").")
        guard panel.runModal() == .OK else {
            return
        }
        upload(panel.urls)
    }

    func requestDownload(_ items: [RemoteItem]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Download Here")
        panel.directoryURL = app.settings.downloadFolder
        guard panel.runModal() == .OK, let folder = panel.url else {
            return
        }
        download(items, to: folder)
    }

    /// Toggles Quick Look for the first selected file. Pressed again while the
    /// file is still copying, it cancels instead.
    func toggleQuickLook() async {
        if previewURL != nil {
            previewURL = nil
            return
        }
        if previewTask != nil {
            cancelPreview()
            return
        }
        guard let deviceID, let item = selectedItems.first(where: { !$0.isDirectory }) else {
            return
        }

        let task = Task { await preparePreview(item, deviceID: deviceID) }
        previewTask = task
        await task.value
    }

    /// A plain click on empty space in the file area dismisses the floating inspector.
    func emptyAreaClicked() {
        if isInspectorShown {
            isInspectorShown = false
        }
    }

    func cancelPreview() {
        previewTask?.cancel()
    }

    private func preparePreview(_ item: RemoteItem, deviceID: String) async {
        // Small files open before the panel would even appear; don't flash it.
        let reveal = Task {
            try await Task.sleep(for: Self.previewPanelDelay)
            previewPreparation = PreviewPreparation(name: item.name, fraction: 0)
        }
        let received = ReceivedBytes()
        defer {
            reveal.cancel()
            previewPreparation = nil
            previewTask = nil
        }

        do {
            let url = try await app.previews.localCopy(of: item, on: deviceID) { [weak self] bytes in
                let total = received.add(bytes)
                Task { @MainActor in self?.updatePreviewProgress(total, of: item.size) }
            }
            guard !Task.isCancelled else {
                return
            }
            previewURL = url
        } catch is CancellationError {
            return
        } catch {
            operationError = error.localizedDescription
        }
    }

    /// Redraws only when the bar would visibly move.
    private func updatePreviewProgress(_ received: UInt64, of size: UInt64) {
        guard let current = previewPreparation, size > 0 else {
            return
        }
        let fraction = min(1, Double(received) / Double(size))
        if fraction - current.fraction >= Self.previewProgressStep {
            previewPreparation?.fraction = fraction
        }
    }

    private static let previewPanelDelay: Duration = .milliseconds(400)
    private static let previewProgressStep = 0.01

    /// Picks the first storage of the first online phone when nothing is selected.
    func selectDefaultIfNeeded() {
        if let sidebarSelection, app.devices.device(id: sidebarSelection.deviceID)?.state == .online {
            return
        }
        guard let device = app.onlineDevices.first, let storage = app.storages[device.id]?.first else {
            return
        }
        sidebarSelection = .storage(deviceID: device.id, rootPath: storage.rootPath)

        // Development aid: `open DroidCargo.app --args -openPath /storage/emulated/0/DCIM`.
        if let path = UserDefaults.standard.string(forKey: Self.openPathArgument), path.hasPrefix(storage.rootPath) {
            navigate(to: path)
        }
    }

    private static let openPathArgument = "openPath"
}
