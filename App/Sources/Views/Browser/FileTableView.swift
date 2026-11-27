import AppKit
import CargoServices
import SwiftUI
import UniformTypeIdentifiers

/// Finder-style list backed by NSTableView. Only visible rows exist, cells are
/// reused, and SwiftUI never diffs the full item list.
struct FileTableView: NSViewRepresentable {
    let browser: BrowserModel

    func makeCoordinator() -> TableCoordinator {
        TableCoordinator(browser: browser)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FileTable()
        table.coordinator = context.coordinator
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.rowHeight = TableMetrics.rowHeight
        table.intercellSpacing = NSSize(width: 6, height: 2)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(TableCoordinator.doubleClicked(_:))
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.draggingDestinationFeedbackStyle = .regular
        table.autosaveName = "FileTable"
        table.autosaveTableColumns = true

        for column in TableColumn.allCases {
            table.addTableColumn(column.makeColumn())
        }
        context.coordinator.tableView = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // Read here so SwiftUI updates the header when the sort changes elsewhere.
        _ = (browser.app.settings.sortKey, browser.app.settings.sortDirection)
        context.coordinator.update(items: browser.visibleItems, selection: browser.selection)
    }
}

enum TableMetrics {
    static let rowHeight: CGFloat = 22
    static let iconSize: CGFloat = 16
    static let thumbnailPixels = 48
}

/// Column definitions; identifiers double as sort keys.
enum TableColumn: String, CaseIterable {
    case name
    case modified
    case size
    case kind

    var title: String {
        switch self {
        case .name: String(localized: "Name")
        case .modified: String(localized: "Date Modified")
        case .size: String(localized: "Size")
        case .kind: String(localized: "Kind")
        }
    }

    var widths: (min: CGFloat, ideal: CGFloat) {
        switch self {
        case .name: (180, 340)
        case .modified: (110, 170)
        case .size: (60, 80)
        case .kind: (80, 130)
        }
    }

    func makeColumn() -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(rawValue))
        column.title = title
        column.minWidth = widths.min
        column.width = widths.ideal
        column.sortDescriptorPrototype = sortDescriptor(ascending: sortKey.defaultDirection == .ascending)
        if self == .size {
            column.headerCell.alignment = .right
        }
        return column
    }

    func sortDescriptor(ascending: Bool) -> NSSortDescriptor {
        NSSortDescriptor(key: rawValue, ascending: ascending)
    }

    var sortKey: SortKey {
        switch self {
        case .name: .name
        case .modified: .dateModified
        case .size: .size
        case .kind: .kind
        }
    }

    init?(_ key: SortKey) {
        guard let column = Self.allCases.first(where: { $0.sortKey == key }) else {
            return nil
        }
        self = column
    }
}

// MARK: - Coordinator

final class TableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSFilePromiseProviderDelegate {
    private static let dateStyle = Date.FormatStyle(date: .abbreviated, time: .shortened)

    let browser: BrowserModel
    weak var tableView: NSTableView?
    private(set) var items: [RemoteItem] = []
    private var isApplyingSelection = false
    private var isApplyingSort = false
    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(browser: BrowserModel) {
        self.browser = browser
    }

    func update(items newItems: [RemoteItem], selection: Set<RemoteItem.ID>) {
        guard let tableView else {
            return
        }
        applySort(key: browser.app.settings.sortKey, direction: browser.app.settings.sortDirection, to: tableView)
        if newItems != items {
            items = newItems
            tableView.reloadData()
        }

        let wanted = IndexSet(items.indices.filter { selection.contains(items[$0].id) })
        if wanted != tableView.selectedRowIndexes {
            isApplyingSelection = true
            tableView.selectRowIndexes(wanted, byExtendingSelection: false)
            isApplyingSelection = false
        }
    }

    var selectedItems: [RemoteItem] {
        tableView?.selectedRowIndexes.compactMap { items[safe: $0] } ?? []
    }

    // MARK: Data

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier, let column = TableColumn(rawValue: identifier.rawValue), let item = items[safe: row] else {
            return nil
        }

        if column == .name {
            let cell = tableView.makeView(withIdentifier: NameCell.identifier, owner: nil) as? NameCell ?? NameCell()
            cell.configure(item, browser: browser)
            return cell
        }

        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? Self.makeTextCell(identifier)
        let text: String
        switch column {
        case .modified:
            text = item.modified.formatted(Self.dateStyle)
        case .size:
            text = item.isDirectory ? "--" : Int64(item.size).formatted(.byteCount(style: .file))
        case .kind:
            text = FileCategory.kindDescription(for: item)
        case .name:
            text = item.name
        }
        cell.textField?.stringValue = text
        cell.textField?.alignment = column == .size ? .right : .left
        return cell
    }

    private static func makeTextCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: Sorting, selection, type-select

    /// Header clicks change the shared sort setting, which the grid and menus use too.
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isApplyingSort,
              let descriptor = tableView.sortDescriptors.first,
              let column = descriptor.key.flatMap(TableColumn.init(rawValue:)) else {
            return
        }
        let settings = browser.app.settings
        settings.sortKey = column.sortKey
        settings.sortDirection = descriptor.ascending ? .ascending : .descending
    }

    /// Shows the setting's sort in the header (it may have changed from the menu).
    private func applySort(key: SortKey, direction: SortDirection, to tableView: NSTableView) {
        guard let column = TableColumn(key) else {
            return
        }
        let wanted = column.sortDescriptor(ascending: direction == .ascending)
        guard tableView.sortDescriptors.first != wanted else {
            return
        }
        isApplyingSort = true
        tableView.sortDescriptors = [wanted]
        isApplyingSort = false
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection, let tableView else {
            return
        }
        browser.selection = Set(tableView.selectedRowIndexes.compactMap { items[safe: $0]?.id })
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        tableColumn?.identifier.rawValue == TableColumn.name.rawValue ? items[safe: row]?.name : nil
    }

    // MARK: Actions

    @objc func doubleClicked(_ sender: NSTableView) {
        open(at: sender.clickedRow)
    }

    func open(at row: Int) {
        guard let item = items[safe: row] else {
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

    func menu(for items: [RemoteItem]) -> NSMenu {
        ItemMenuBuilder(browser: browser, items: items).build()
    }

    // MARK: Drag out

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard let item = items[safe: row] else {
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

    // MARK: Drop in

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard (info.draggingSource as? NSTableView) !== tableView else {
            return []
        }
        if dropOperation == .on, items[safe: row]?.isDirectory == true {
            return .copy
        }
        // Anywhere else means "this folder": highlight the whole table.
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty else {
            return false
        }
        let folder = row >= 0 ? items[safe: row]?.path : nil
        browser.upload(urls, into: folder)
        return true
    }
}

// MARK: - Table and cells

/// Adds Finder's keys: Space for Quick Look, ⌘↓ to open, ⌘⌫ to delete.
final class FileTable: NSTableView {
    weak var coordinator: TableCoordinator?

    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        let start = NSEvent.mouseLocation
        super.mouseDown(with: event)

        // Click below the last row (not a drag) dismisses the floating inspector.
        if row < 0, EmptyAreaClick.isClick(from: start) {
            coordinator?.browser.emptyAreaClicked()
        }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == KeyCode.space, flags.isEmpty {
            coordinator?.quickLook()
            return
        }
        if event.keyCode == KeyCode.downArrow, flags == .command {
            coordinator?.open(at: selectedRow)
            return
        }
        if event.keyCode == KeyCode.return, flags.isEmpty {
            coordinator?.browser.renameSelection()
            return
        }
        if (event.keyCode == KeyCode.delete && flags == .command) {
            coordinator?.deleteSelection()
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let coordinator else {
            return nil
        }
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else {
            return nil
        }
        // Right-clicking outside the selection selects that row first, like Finder.
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes([row], byExtendingSelection: false)
        }
        return coordinator.menu(for: coordinator.selectedItems)
    }
}

enum KeyCode {
    static let space: UInt16 = 49
    static let `return`: UInt16 = 36
    static let delete: UInt16 = 51
    static let downArrow: UInt16 = 125
}

/// Icon (or photo thumbnail) and file name.
final class NameCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("NameCell")

    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private var loadTask: Task<Void, Never>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        name.lineBreakMode = .byTruncatingMiddle
        name.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(name)
        imageView = icon
        textField = name
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: TableMetrics.iconSize),
            icon.heightAnchor.constraint(equalToConstant: TableMetrics.iconSize),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(_ item: RemoteItem, browser: BrowserModel) {
        loadTask?.cancel()
        name.stringValue = item.name
        icon.image = FileIcons.icon(for: item)
        setAccessibilityLabel(item.name)

        guard ThumbnailService.canPreview(item), let deviceID = browser.deviceID else {
            return
        }
        loadTask = Task { [weak self, thumbnails = browser.app.thumbnails] in
            let image = await thumbnails.thumbnail(for: item, deviceID: deviceID, maxPixelSize: TableMetrics.thumbnailPixels)
            guard !Task.isCancelled, let image else {
                return
            }
            self?.icon.image = NSImage(cgImage: image, size: .zero)
        }
    }
}
