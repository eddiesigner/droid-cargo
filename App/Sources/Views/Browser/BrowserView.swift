import CargoServices
import QuickLook
import SwiftUI

struct BrowserView: View {
    @Bindable var browser: BrowserModel
    @State private var isDropTargeted = false

    private var settings: AppSettings { browser.app.settings }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .trailing) { inspectorPanel }
                .animation(Self.inspectorAnimation, value: browser.isInspectorShown)
            BottomBars(browser: browser)
        }
        .navigationTitle(browser.breadcrumbs.last?.name ?? "")
        .navigationSubtitle(browser.device?.name ?? "")
        .searchable(text: $browser.searchText, placement: .toolbar, prompt: "Search This Folder")
        .toolbar { BrowserToolbar(browser: browser) }
        .dropDestination(for: URL.self) { urls, _ in
            browser.upload(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay { dropHighlight }
        .overlay {
            if let preparation = browser.previewPreparation {
                PreviewPreparationPanel(preparation: preparation, cancel: browser.cancelPreview)
            }
        }
        .quickLookPreview($browser.previewURL)
        .sheet(isPresented: $browser.isNewFolderShown) {
            NameSheet(title: "New Folder", actionTitle: "Create", initialName: String(localized: "untitled folder")) { name in
                try await browser.makeFolder(named: name)
            }
        }
        .sheet(item: $browser.renameTarget) { item in
            NameSheet(title: "Rename", actionTitle: "Rename", initialName: item.name) { name in
                try await browser.rename(item, to: name)
            }
        }
        .sheet(isPresented: $browser.isPhotoImportShown) {
            PhotoImportSheet(browser: browser)
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(get: { !browser.pendingDeletion.isEmpty }, set: { if !$0 { browser.pendingDeletion = [] } })
        ) {
            Button("Delete", role: .destructive) {
                let items = browser.pendingDeletion
                Task {
                    do {
                        try await browser.delete(items)
                    } catch {
                        browser.operationError = error.localizedDescription
                    }
                }
            }
        } message: {
            Text("This can’t be undone. Android has no Trash for files deleted over USB.")
        }
        .alert("The Action Couldn’t Be Completed", isPresented: Binding(get: { browser.operationError != nil }, set: { if !$0 { browser.operationError = nil } })) {
            Button("OK") {}
        } message: {
            Text(browser.operationError ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch browser.state {
        case .failed(let message) where browser.items.isEmpty:
            ContentUnavailableView {
                Label("Couldn’t Open Folder", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { browser.refresh() }
            }
        case .loading where browser.items.isEmpty:
            ProgressView("Loading…")
                .controlSize(.small)
        default:
            if browser.visibleItems.isEmpty {
                emptyFolder
            } else if settings.layout == .grid {
                CollectionGridView(browser: browser, iconSize: settings.gridThumbnailSize)
            } else {
                FileTableView(browser: browser)
            }
        }
    }

    @ViewBuilder
    private var emptyFolder: some View {
        if browser.searchText.isEmpty {
            ContentUnavailableView("Empty Folder", systemImage: "folder", description: Text("Drag files here from Finder to copy them to your phone."))
        } else {
            ContentUnavailableView.search(text: browser.searchText)
        }
    }

    /// Floats over the files instead of taking room from them. As a column
    /// it made the grid reflow (items jumped) and, when hidden, left a
    /// collapsed edge that dragging the scroll bar could pull open.
    @ViewBuilder
    private var inspectorPanel: some View {
        if browser.isInspectorShown {
            InspectorView(browser: browser)
                .frame(width: Self.inspectorWidth)
                .frame(maxHeight: .infinity)
                // Tinted so busy thumbnails behind it don't hurt readability.
                .glassEffect(.regular.tint(Self.inspectorTint), in: .rect(cornerRadius: Self.inspectorCornerRadius))
                .padding(Self.inspectorMargin)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    private static let inspectorWidth: CGFloat = 280
    private static let inspectorCornerRadius: CGFloat = 16
    private static let inspectorMargin: CGFloat = 8
    private static let inspectorTint = Color(nsColor: .windowBackgroundColor).opacity(0.75)
    private static let inspectorAnimation = Animation.snappy(duration: 0.2)

    @ViewBuilder
    private var dropHighlight: some View {
        if isDropTargeted {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .background(Color.accentColor.opacity(0.06), in: .rect(cornerRadius: 12))
                .padding(6)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var deletionTitle: String {
        let items = browser.pendingDeletion
        if items.count == 1, let item = items.first {
            return String(localized: "Delete “\(item.name)” from your phone?")
        }
        return String(localized: "Delete \(items.count) items from your phone?")
    }
}

/// Context menu shared by the list and grid.
struct ItemContextMenu: View {
    let browser: BrowserModel
    let items: [RemoteItem]

    var body: some View {
        if let item = items.first, items.count == 1, item.isDirectory {
            Button("Open") { browser.open(item) }
            Divider()
        }
        Button(items.count == 1 ? "Download" : "Download \(items.count) Items") { browser.download(items) }
        Button("Download To…") { browser.requestDownload(items) }
        if items.contains(where: { !$0.isDirectory }) {
            Button("Quick Look") { Task { await browser.toggleQuickLook() } }
        }
        Divider()
        if let item = items.first, items.count == 1 {
            Button("Rename…") { browser.renameTarget = item }
            if item.isDirectory, let deviceID = browser.deviceID {
                let isFavorite = browser.app.settings.isFavorite(item.path, deviceID: deviceID)
                Button(isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                    browser.app.settings.toggleFavorite(item.path, deviceID: deviceID)
                }
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
            }
            Divider()
        }
        Button("Delete…", role: .destructive) { browser.pendingDeletion = items }
    }
}

/// Shown while a large file copies to the Mac for Quick Look, which can take
/// a while for long videos. Esc or Space cancels.
private struct PreviewPreparationPanel: View {
    let preparation: PreviewPreparation
    let cancel: () -> Void

    private static let width: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preparing Preview…")
                .font(.headline)
            Text(preparation.name)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            ProgressView(value: preparation.fraction)
            HStack {
                Text(preparation.fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: Self.width)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .shadow(radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preparing preview of \(preparation.name)")
    }
}
