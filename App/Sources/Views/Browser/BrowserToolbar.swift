import CargoServices
import SwiftUI

struct BrowserToolbar: ToolbarContent {
    @Bindable var browser: BrowserModel

    private var settings: AppSettings { browser.app.settings }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            ControlGroup {
                Button("Back", systemImage: "chevron.left") { browser.goBack() }
                    .disabled(!browser.canGoBack)
                Button("Forward", systemImage: "chevron.right") { browser.goForward() }
                    .disabled(!browser.canGoForward)
            }
            .controlGroupStyle(.navigation)
        }

        ToolbarItem {
            Picker("View", selection: Binding(get: { settings.layout }, set: { settings.layout = $0 })) {
                Label("List", systemImage: "list.bullet").tag(BrowserLayout.list)
                Label("Grid", systemImage: "square.grid.2x2").tag(BrowserLayout.grid)
            }
            .pickerStyle(.segmented)
            .help("Change how items are shown")
        }

        ToolbarItemGroup {
            Button("New Folder", systemImage: "folder.badge.plus") { browser.isNewFolderShown = true }
                .help("Create a folder on the phone")
            Button("Upload", systemImage: "square.and.arrow.up") { browser.requestUpload() }
                .help("Copy files from this Mac to the phone (⇧⌘U)")
            Button("Download", systemImage: "square.and.arrow.down") { browser.download(browser.selectedItems) }
                .disabled(browser.selection.isEmpty)
                .help("Copy the selection to \(settings.downloadFolder.lastPathComponent)")
        }

        ToolbarItem {
            TransfersButton(app: browser.app)
        }

        ToolbarItem {
            Button("Inspector", systemImage: "info.circle") { browser.isInspectorShown.toggle() }
                .help("Show or hide details")
        }
    }
}

/// Finder-style path bar with item count and free space.
struct PathBar: View {
    let browser: BrowserModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(browser.breadcrumbs.enumerated()), id: \.offset) { index, crumb in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                Button {
                    browser.navigate(to: crumb.path)
                } label: {
                    Label(crumb.name, systemImage: index == 0 ? "internaldrive" : "folder.fill")
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(index == browser.breadcrumbs.count - 1 ? .primary : .secondary)
            }
            Spacer(minLength: 12)
            Text(status)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Path")
    }

    private var status: String {
        let count = browser.visibleItems.count
        let items = count == 1 ? String(localized: "1 item") : String(localized: "\(count) items")
        let selected = browser.selection.isEmpty ? "" : String(localized: "\(browser.selection.count) selected, ")
        guard let storage = browser.storage else {
            return selected + items
        }
        let free = Int64(storage.freeBytes).formatted(.byteCount(style: .file))
        return "\(selected)\(items), \(free) available"
    }
}
