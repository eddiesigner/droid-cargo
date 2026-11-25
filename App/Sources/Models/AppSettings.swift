import CargoServices
import Foundation
import Observation

enum BrowserLayout: String, CaseIterable {
    case list
    case grid
}

enum PhotoOrganization: String, CaseIterable {
    case flat
    case byMonth
}

/// User preferences, persisted in UserDefaults.
@Observable
final class AppSettings {
    private enum Key {
        static let downloadFolder = "downloadFolder"
        static let conflictPolicy = "conflictPolicy"
        static let fileDates = "fileDates"
        static let parallelTransfers = "parallelTransfers"
        static let showHiddenFiles = "showHiddenFiles"
        static let layout = "layout"
        static let gridThumbnailSize = "gridThumbnailSize"
        static let notifyWhenDone = "notifyWhenDone"
        static let revealAfterDownload = "revealAfterDownload"
        static let scanMedia = "scanMedia"
        static let photoOrganization = "photoOrganization"
        static let customADBPath = "customADBPath"
        static let favorites = "favorites"
        static let hasCompletedWelcome = "hasCompletedWelcome"
    }

    static let parallelRange = 1...4
    static let gridSizeRange: ClosedRange<Double> = 80...240

    private let defaults: UserDefaults

    var downloadFolder: URL {
        didSet { defaults.set(downloadFolder.path, forKey: Key.downloadFolder) }
    }
    var conflictPolicy: ConflictPolicy {
        didSet { defaults.set(conflictPolicy.rawValue, forKey: Key.conflictPolicy) }
    }
    var fileDates: FileDatePolicy {
        didSet { defaults.set(fileDates.rawValue, forKey: Key.fileDates) }
    }
    var parallelTransfers: Int {
        didSet { defaults.set(parallelTransfers, forKey: Key.parallelTransfers) }
    }
    var showHiddenFiles: Bool {
        didSet { defaults.set(showHiddenFiles, forKey: Key.showHiddenFiles) }
    }
    var layout: BrowserLayout {
        didSet { defaults.set(layout.rawValue, forKey: Key.layout) }
    }
    var gridThumbnailSize: Double {
        didSet { defaults.set(gridThumbnailSize, forKey: Key.gridThumbnailSize) }
    }
    var notifyWhenDone: Bool {
        didSet { defaults.set(notifyWhenDone, forKey: Key.notifyWhenDone) }
    }
    var revealAfterDownload: Bool {
        didSet { defaults.set(revealAfterDownload, forKey: Key.revealAfterDownload) }
    }
    var scanMedia: Bool {
        didSet { defaults.set(scanMedia, forKey: Key.scanMedia) }
    }
    var photoOrganization: PhotoOrganization {
        didSet { defaults.set(photoOrganization.rawValue, forKey: Key.photoOrganization) }
    }
    var customADBPath: String {
        didSet { defaults.set(customADBPath, forKey: Key.customADBPath) }
    }
    /// Set once the user leaves the first-launch welcome screen.
    var hasCompletedWelcome: Bool {
        didSet { defaults.set(hasCompletedWelcome, forKey: Key.hasCompletedWelcome) }
    }
    /// Pinned folders, keyed by device serial.
    var favorites: [String: [String]] {
        didSet { defaults.set(favorites, forKey: Key.favorites) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        downloadFolder = defaults.string(forKey: Key.downloadFolder).map { URL(filePath: $0) } ?? .downloadsDirectory
        conflictPolicy = defaults.string(forKey: Key.conflictPolicy).flatMap(ConflictPolicy.init) ?? .ask
        fileDates = defaults.string(forKey: Key.fileDates).flatMap(FileDatePolicy.init) ?? .keepOriginal
        parallelTransfers = defaults.object(forKey: Key.parallelTransfers) as? Int ?? 1
        showHiddenFiles = defaults.bool(forKey: Key.showHiddenFiles)
        layout = defaults.string(forKey: Key.layout).flatMap(BrowserLayout.init) ?? .list
        gridThumbnailSize = defaults.object(forKey: Key.gridThumbnailSize) as? Double ?? 128
        notifyWhenDone = defaults.object(forKey: Key.notifyWhenDone) as? Bool ?? true
        revealAfterDownload = defaults.bool(forKey: Key.revealAfterDownload)
        scanMedia = defaults.object(forKey: Key.scanMedia) as? Bool ?? true
        photoOrganization = defaults.string(forKey: Key.photoOrganization).flatMap(PhotoOrganization.init) ?? .byMonth
        customADBPath = defaults.string(forKey: Key.customADBPath) ?? ""
        favorites = defaults.dictionary(forKey: Key.favorites) as? [String: [String]] ?? [:]
        hasCompletedWelcome = defaults.bool(forKey: Key.hasCompletedWelcome)
    }

    var transferOptions: TransferOptions {
        TransferOptions(conflictPolicy: conflictPolicy, parallelism: parallelTransfers, scanMediaAfterUpload: scanMedia, dates: fileDates)
    }

    func isFavorite(_ path: String, deviceID: String) -> Bool {
        favorites[deviceID, default: []].contains(path)
    }

    func toggleFavorite(_ path: String, deviceID: String) {
        var list = favorites[deviceID, default: []]
        if let index = list.firstIndex(of: path) {
            list.remove(at: index)
        } else {
            list.append(path)
        }
        favorites[deviceID] = list
    }
}
