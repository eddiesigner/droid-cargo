import AppKit
import CargoServices
import SwiftUI
import UniformTypeIdentifiers

/// Finder-style icon view backed by NSCollectionView: native selection,
/// rubber-band, keyboard navigation, type-to-select, and file-promise drags.
struct CollectionGridView: NSViewRepresentable {
    let browser: BrowserModel
    let iconSize: CGFloat

    func makeCoordinator() -> GridCoordinator {
        GridCoordinator(browser: browser)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = GridMetrics.spacing
        layout.minimumLineSpacing = GridMetrics.spacing
        layout.sectionInset = NSEdgeInsets(top: GridMetrics.spacing, left: GridMetrics.spacing, bottom: GridMetrics.spacing, right: GridMetrics.spacing)

        let collection = FileCollectionView()
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.allowsEmptySelection = true
        collection.backgroundColors = [.clear]
        collection.register(FileCollectionItem.self, forItemWithIdentifier: FileCollectionItem.identifier)
        collection.dataSource = context.coordinator
        collection.delegate = context.coordinator
        collection.coordinator = context.coordinator
        collection.registerForDraggedTypes([.fileURL])
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        collection.setAccessibilityLabel(String(localized: "Files"))
        context.coordinator.collectionView = collection

        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(items: browser.visibleItems, selection: browser.selection, iconSize: iconSize)
    }
}

enum GridMetrics {
    static let spacing: CGFloat = 12
    static let labelHeight: CGFloat = 34
    static let padding: CGFloat = 6

    static func itemSize(for iconSize: CGFloat) -> NSSize {
        NSSize(width: iconSize + padding * 4, height: iconSize + padding * 2 + labelHeight)
    }
}

// MARK: - Coordinator

final class GridCoordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSFilePromiseProviderDelegate {
    private static let typeSelectTimeout: TimeInterval = 1

    let browser: BrowserModel
    weak var collectionView: NSCollectionView?
    private(set) var items: [RemoteItem] = []
    private var iconSize: CGFloat = 0
    private var isApplyingSelection = false
    private var typeSelectBuffer = ""
    private var lastTypeSelect = Date.distantPast
    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(browser: BrowserModel) {
        self.browser = browser
    }

    func update(items newItems: [RemoteItem], selection: Set<RemoteItem.ID>, iconSize newSize: CGFloat) {
        guard let collectionView else {
            return
        }
        if newSize != iconSize, let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout {
            iconSize = newSize
            layout.itemSize = GridMetrics.itemSize(for: newSize)
            collectionView.reloadData()
        }
        if newItems != items {
            items = newItems
            collectionView.reloadData()
        }

        let wanted = Set(items.indices.filter { selection.contains(items[$0].id) }.map { IndexPath(item: $0, section: 0) })
        if wanted != collectionView.selectionIndexPaths {
            isApplyingSelection = true
            collectionView.selectionIndexPaths = wanted
            isApplyingSelection = false
        }
    }

    // MARK: Data source

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: FileCollectionItem.identifier, for: indexPath)
        if let cell = cell as? FileCollectionItem {
            cell.configure(items[indexPath.item], iconSize: iconSize, browser: browser)
        }
        return cell
    }

    // MARK: Selection

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        syncSelection()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        syncSelection()
    }

    private func syncSelection() {
        guard !isApplyingSelection, let collectionView else {
            return
        }
        browser.selection = Set(collectionView.selectionIndexPaths.compactMap { items[safe: $0.item]?.id })
    }

    var selectedItems: [RemoteItem] {
        collectionView?.selectionIndexPaths.sorted().compactMap { items[safe: $0.item] } ?? []
    }

    // MARK: Actions

    func open(at index: Int) {
        guard let item = items[safe: index] else {
            return
        }
        if item.isDirectory {
            browser.open(item)
            return
        }
        Task { await browser.toggleQuickLook() }
    }

    func quickLook() {
        Task { await browser.toggleQuickLook() }
    }

    func deleteSelection() {
        let selected = selectedItems
        if !selected.isEmpty {
            browser.pendingDeletion = selected
        }
    }

    /// Finder-style type-to-select: typing "ph" jumps to the first name starting with it.
    func typeSelect(_ characters: String) {
        let now = Date()
        if now.timeIntervalSince(lastTypeSelect) > Self.typeSelectTimeout {
            typeSelectBuffer = ""
        }
        lastTypeSelect = now
        typeSelectBuffer += characters

        guard let index = items.firstIndex(where: {
            $0.name.range(of: typeSelectBuffer, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
        }) else {
            return
        }
        let path = IndexPath(item: index, section: 0)
        collectionView?.selectionIndexPaths = [path]
        collectionView?.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
        syncSelection()
    }

    func menu(for items: [RemoteItem]) -> NSMenu {
        ItemMenuBuilder(browser: browser, items: items).build()
    }

    // MARK: Drag out (file promises, so Finder decides where files land)

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        guard let item = items[safe: indexPath.item] else {
            return nil
        }
        let type = item.isDirectory ? UTType.folder : (UTType(filenameExtension: item.fileExtension) ?? .data)
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
        provider.userInfo = item
        return provider
    }

    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (provider.userInfo as? RemoteItem)?.name ?? "File"
    }

    nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        MainActor.assumeIsolated { promiseQueue }
    }

    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping @Sendable (Error?) -> Void) {
        let item = provider.userInfo as? RemoteItem
        Task { @MainActor in
            guard let item else {
                completionHandler(nil)
                return
            }
            do {
                guard let device = browser.device else {
                    throw DeviceError.deviceDisconnected
                }
                let local = try await browser.app.exportForDrag(item, from: device)
                try FileManager.default.moveItem(at: local, to: url)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    // MARK: Drop in (upload into the current folder or onto a folder)

    func collectionView(
        _ collectionView: NSCollectionView,
        validateDrop draggingInfo: any NSDraggingInfo,
        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        guard (draggingInfo.draggingSource as? NSCollectionView) !== collectionView else {
            return []
        }
        let index = (proposedIndexPath.pointee as IndexPath).item
        if dropOperation.pointee == .on, items[safe: index]?.isDirectory != true {
            // Dropping onto a file means "this folder".
            dropOperation.pointee = .before
        }
        return .copy
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        acceptDrop draggingInfo: any NSDraggingInfo,
        indexPath: IndexPath,
        dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = draggingInfo.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty else {
            return false
        }
        let folder = dropOperation == .on ? items[safe: indexPath.item]?.path : nil
        browser.upload(urls, into: folder)
        return true
    }
}

// MARK: - Collection view

/// Adds Finder's keyboard and mouse conventions on top of NSCollectionView.
final class FileCollectionView: NSCollectionView {
    weak var coordinator: GridCoordinator?

    /// Where a press on empty space began; checked on release, because the
    /// collection view returns from mouseDown before a rubber-band drag ends.
    private var emptyPressStart: NSPoint?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        emptyPressStart = indexPathForItem(at: point) == nil ? NSEvent.mouseLocation : nil
        super.mouseDown(with: event)

        guard event.clickCount == 2 else {
            return
        }
        if let path = indexPathForItem(at: point) {
            coordinator?.open(at: path.item)
        }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        // A pointer that barely moved means a click, not a rubber-band drag.
        if let start = emptyPressStart, EmptyAreaClick.isClick(from: start) {
            coordinator?.browser.emptyAreaClicked()
        }
        emptyPressStart = nil
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])

        if event.keyCode == KeyCode.space, flags.isEmpty {
            coordinator?.quickLook()
            return
        }
        if event.keyCode == KeyCode.downArrow, flags == .command {
            if let index = selectionIndexPaths.first?.item {
                coordinator?.open(at: index)
            }
            return
        }
        if event.keyCode == KeyCode.return, flags.isEmpty {
            coordinator?.browser.renameSelection()
            return
        }
        if event.keyCode == KeyCode.delete, flags == .command {
            coordinator?.deleteSelection()
            return
        }
        if flags.subtracting(.shift).isEmpty, let characters = event.characters, Self.isTypeSelectText(characters) {
            coordinator?.typeSelect(characters)
            return
        }
        super.keyDown(with: event)
    }

    private static func isTypeSelectText(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || CharacterSet.punctuationCharacters.contains($0)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let coordinator else {
            return nil
        }
        let point = convert(event.locationInWindow, from: nil)
        guard let path = indexPathForItem(at: point) else {
            return nil
        }
        // Right-clicking outside the selection selects that item first, like Finder.
        if !selectionIndexPaths.contains(path) {
            selectionIndexPaths = [path]
            delegate?.collectionView?(self, didSelectItemsAt: [path])
        }
        return coordinator.menu(for: coordinator.selectedItems)
    }
}

/// Tells a click on empty space apart from the start of a rubber-band drag.
enum EmptyAreaClick {
    /// Further than this and the gesture was a drag.
    private static let maxTravel: CGFloat = 3

    static func isClick(from start: NSPoint) -> Bool {
        let end = NSEvent.mouseLocation
        return hypot(end.x - start.x, end.y - start.y) <= maxTravel
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
