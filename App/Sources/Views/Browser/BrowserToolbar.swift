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

        ToolbarItem {
            Menu("Sort By", systemImage: "arrow.up.and.down.text.horizontal") {
                SortMenuItems(settings: settings)
            }
            .help("Change the order of items")
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

/// Sort key and direction, checkmarked. Shared by the toolbar menu and View › Sort By.
struct SortMenuItems: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Picker("Sort By", selection: Binding(get: { settings.sortKey }, set: { settings.sort(by: $0) })) {
            ForEach(SortKey.allCases, id: \.self) { key in
                Text(key.title)
                    .keyboardShortcut(key.shortcut, modifiers: [.command, .option, .control])
                    .tag(key)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()

        Picker("Order", selection: $settings.sortDirection) {
            Text("Ascending").tag(SortDirection.ascending)
            Text("Descending").tag(SortDirection.descending)
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}

private extension SortKey {
    /// Finder's View › Sort By shortcuts (⌃⌥⌘ plus this key).
    var shortcut: KeyEquivalent {
        switch self {
        case .name: "1"
        case .kind: "2"
        case .dateModified: "5"
        case .size: "7"
        }
    }
}

/// Finder's bottom bars: path bar (NSPathControl) above a centered status bar.
struct BottomBars: View {
    let browser: BrowserModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            PathControl(crumbs: browser.breadcrumbs) { browser.navigate(to: $0) }
                .frame(height: 22)
                .padding(.horizontal, 8)
            Divider()
            ZStack {
                HStack(spacing: 6) {
                    if browser.placing != nil {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(status)
                }
                .font(.system(size: NSFont.smallSystemFontSize))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if browser.app.settings.layout == .grid {
                    HStack {
                        Spacer()
                        Slider(value: Binding(get: { browser.app.settings.gridThumbnailSize }, set: { browser.app.settings.gridThumbnailSize = $0 }), in: AppSettings.gridSizeRange)
                            .controlSize(.mini)
                            .frame(width: 90)
                            .accessibilityLabel("Icon size")
                    }
                }
            }
            .frame(height: 22)
            .padding(.horizontal, 10)
        }
        .background(.bar)
    }

    /// Finder wording: "1 of 7,913 selected, 45.2 GB available".
    private var status: String {
        switch browser.placing {
        case .copy: return String(localized: "Copying…")
        case .move: return String(localized: "Moving…")
        case nil: break
        }
        let count = browser.visibleItems.count
        let selectedCount = browser.selection.count
        var text = selectedCount > 0
            ? String(localized: "\(selectedCount) of \(count) selected")
            : (count == 1 ? String(localized: "1 item") : String(localized: "\(count) items"))
        if let storage = browser.storage {
            text += String(localized: ", \(Int64(storage.freeBytes).formatted(.byteCount(style: .file))) available")
        }
        return text
    }
}

/// Native path control; clicking a segment opens that folder.
struct PathControl: NSViewRepresentable {
    let crumbs: [(name: String, path: String)]
    let navigate: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSPathControl {
        let control = NSPathControl()
        control.pathStyle = .standard
        control.controlSize = .small
        control.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        control.focusRingType = .none
        control.target = context.coordinator
        control.action = #selector(Coordinator.clicked(_:))
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSPathControl, context: Context) {
        context.coordinator.navigate = navigate
        let paths = crumbs.map(\.path)
        guard paths != context.coordinator.paths else {
            return
        }
        context.coordinator.paths = paths
        let folderIcon = NSWorkspace.shared.icon(for: .folder)
        control.pathItems = crumbs.enumerated().map { index, crumb in
            let item = NSPathControlItem()
            item.title = crumb.name
            item.image = index == 0 ? NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil) : folderIcon
            return item
        }
    }

    final class Coordinator: NSObject {
        var paths: [String] = []
        var navigate: (String) -> Void = { _ in }

        @objc func clicked(_ control: NSPathControl) {
            guard let item = control.clickedPathItem, let index = control.pathItems.firstIndex(of: item), paths.indices.contains(index) else {
                return
            }
            navigate(paths[index])
        }
    }
}
