import CargoServices
import SwiftUI

struct FileGridView: View {
    @Bindable var browser: BrowserModel
    private static let spacing: CGFloat = 16
    private static let labelHeight: CGFloat = 34

    private var size: CGFloat { browser.app.settings.gridThumbnailSize }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: size + 12), spacing: Self.spacing)], spacing: Self.spacing) {
                ForEach(browser.visibleItems) { item in
                    GridCell(item: item, browser: browser, size: size, isSelected: browser.selection.contains(item.id))
                        .onTapGesture(count: 2) { open(item) }
                        .simultaneousGesture(TapGesture().modifiers(.command).onEnded { toggle(item) })
                        .onTapGesture { browser.selection = [item.id] }
                        .contextMenu {
                            ItemContextMenu(browser: browser, items: contextItems(for: item))
                        }
                        .draggable(DraggedRemoteItem(item: item, browser: browser))
                }
            }
            .padding(Self.spacing)
        }
        .background {
            // Clicking empty space clears the selection.
            Color.clear
                .contentShape(.rect)
                .onTapGesture { browser.selection = [] }
        }
        .safeAreaInset(edge: .bottom, alignment: .trailing) {
            Slider(value: Binding(get: { size }, set: { browser.app.settings.gridThumbnailSize = $0 }), in: AppSettings.gridSizeRange)
                .frame(width: 120)
                .controlSize(.mini)
                .padding(8)
                .accessibilityLabel("Thumbnail size")
        }
    }

    private func open(_ item: RemoteItem) {
        if item.isDirectory {
            browser.open(item)
            return
        }
        browser.selection = [item.id]
        Task { await browser.toggleQuickLook() }
    }

    private func toggle(_ item: RemoteItem) {
        if browser.selection.contains(item.id) {
            browser.selection.remove(item.id)
            return
        }
        browser.selection.insert(item.id)
    }

    private func contextItems(for item: RemoteItem) -> [RemoteItem] {
        browser.selection.contains(item.id) ? browser.selectedItems : [item]
    }
}

private struct GridCell: View {
    let item: RemoteItem
    let browser: BrowserModel
    let size: CGFloat
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            FileThumbnail(item: item, browser: browser, size: size, pixels: Int(size * 2))
                .frame(width: size, height: size)
                .padding(4)
                .background(isSelected ? Color.secondary.opacity(0.18) : .clear, in: .rect(cornerRadius: 10))
            Text(item.name)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .foregroundStyle(isSelected ? Color.white : .primary)
                .background(isSelected ? Color.accentColor : .clear, in: .rect(cornerRadius: 4))
                .frame(width: size + 12)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityValue(item.isDirectory ? Text("Folder") : Text(Int64(item.size).formatted(.byteCount(style: .file))))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}
