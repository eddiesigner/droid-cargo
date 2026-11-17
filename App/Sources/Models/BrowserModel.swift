import AppKit
import CargoServices
import Foundation
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
    private(set) var items: [RemoteItem] = []
    private(set) var state: LoadState = .idle
    var selection = Set<RemoteItem.ID>()
    var searchText = ""
    var sortOrder = [KeyPathComparator(\RemoteItem.name, comparator: .localizedStandard)]
    var isInspectorShown = false
    var isPhotoImportShown = false
    var isNewFolderShown = false
    var renameTarget: RemoteItem?
    var pendingDeletion: [RemoteItem] = []
    var operationError: String?
    /// Local copy shown by Quick Look.
    var previewURL: URL?
    private(set) var isPreparingPreview = false

    /// Listings already seen, shown instantly while a fresh one loads.
    private var cache: [String: [RemoteItem]] = [:]
    private var loadTask: Task<Void, Never>?

    init(app: AppModel) {
        self.app = app
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

    /// Filtered and sorted, folders first like Finder's "Keep folders on top".
    var visibleItems: [RemoteItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let filtered = items.filter { item in
            (app.settings.showHiddenFiles || !item.isHidden)
                && (query.isEmpty || item.name.localizedStandardContains(query))
        }
        let sorted = filtered.sorted(using: sortOrder)
        return sorted.filter(\.isDirectory) + sorted.filter { !$0.isDirectory }
    }

    var selectedItems: [RemoteItem] {
        items.filter { selection.contains($0.id) }
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
    func load() async {
        loadTask?.cancel()
        guard let deviceID, let path = currentPath else {
            return
        }
        selection = []
        searchText = ""
        if let cached = cache[path] {
            items = cached
            state = .loaded
        } else {
            items = []
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
        if let currentPath {
            cache[currentPath] = nil
        }
        Task { await load() }
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

    /// Toggles Quick Look for the first selected file.
    func toggleQuickLook() async {
        if previewURL != nil {
            previewURL = nil
            return
        }
        guard let deviceID, let item = selectedItems.first(where: { !$0.isDirectory }) else {
            return
        }
        isPreparingPreview = true
        defer { isPreparingPreview = false }
        do {
            previewURL = try await app.previews.localCopy(of: item, on: deviceID)
        } catch {
            operationError = error.localizedDescription
        }
    }

    /// Picks the first storage of the first online phone when nothing is selected.
    func selectDefaultIfNeeded() {
        if let sidebarSelection, app.devices.device(id: sidebarSelection.deviceID)?.state == .online {
            return
        }
        guard let device = app.onlineDevices.first, let storage = app.storages[device.id]?.first else {
            return
        }
        sidebarSelection = .storage(deviceID: device.id, rootPath: storage.rootPath)
    }
}
