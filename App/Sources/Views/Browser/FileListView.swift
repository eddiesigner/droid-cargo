import CargoServices
import SwiftUI

/// NSTableView-backed list; only visible rows are rendered, so 10k+ items scroll smoothly.
struct FileListView: View {
    @Bindable var browser: BrowserModel
    private static let iconSize: CGFloat = 20
    private static let thumbnailPixels = 64

    var body: some View {
        Table(of: RemoteItem.self, selection: $browser.selection, sortOrder: $browser.sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { item in
                HStack(spacing: 8) {
                    FileThumbnail(item: item, browser: browser, size: Self.iconSize, pixels: Self.thumbnailPixels)
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .width(min: 200, ideal: 340)

            TableColumn("Date Modified", value: \.modified) { item in
                Text(item.modified.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 120, ideal: 170)

            TableColumn("Size", value: \.size) { item in
                Text(item.isDirectory ? "--" : Int64(item.size).formatted(.byteCount(style: .file)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 80)

            TableColumn("Kind") { item in
                Text(FileCategory.kindDescription(for: item))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 130)
        } rows: {
            ForEach(browser.visibleItems) { item in
                TableRow(item)
                    .draggable(DraggedRemoteItem(item: item, browser: browser))
            }
        }
        .contextMenu(forSelectionType: RemoteItem.ID.self) { ids in
            ItemContextMenu(browser: browser, items: browser.items.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            openOrPreview(ids)
        }
        .alternatingRowBackgrounds()
    }

    /// Double-click opens folders and Quick Looks files.
    private func openOrPreview(_ ids: Set<RemoteItem.ID>) {
        let items = browser.items.filter { ids.contains($0.id) }
        if items.count == 1, let item = items.first, item.isDirectory {
            browser.open(item)
            return
        }
        Task { await browser.toggleQuickLook() }
    }
}
