import CargoServices
import SwiftUI

/// One-click import of new photos and videos from the phone's camera folders.
struct PhotoImportSheet: View {
    let browser: BrowserModel

    @Environment(\.dismiss) private var dismiss
    @State private var items: [RemoteItem]?
    @State private var error: String?
    @State private var destination: URL = .picturesDirectory.appending(path: "DroidCargo")

    private static let previewCount = 24
    private static let thumbnailSize: CGFloat = 64

    private var app: AppModel { browser.app }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import Photos & Videos").font(.title3.bold())
                Text("New items from Camera, Screenshots and other picture folders. Items imported before are skipped.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content
                .frame(maxWidth: .infinity, minHeight: 170)

            Form {
                LabeledContent("Save to") {
                    HStack {
                        Text(destination.path(percentEncoded: false))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Picker("Organize", selection: Binding(get: { app.settings.photoOrganization }, set: { app.settings.photoOrganization = $0 })) {
                    Text("Into Year/Month folders").tag(PhotoOrganization.byMonth)
                    Text("All in one folder").tag(PhotoOrganization.flat)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(importTitle, action: startImport)
                    .keyboardShortcut(.defaultAction)
                    .disabled(items?.isEmpty ?? true)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { await scan() }
    }

    @ViewBuilder
    private var content: some View {
        if let error {
            ContentUnavailableView("Couldn’t Scan", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if let items, items.isEmpty {
            ContentUnavailableView("You’re Up to Date", systemImage: "checkmark.circle", description: Text("There are no new photos or videos."))
        } else if let items {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(items.count) new items · \(Int64(items.reduce(0) { $0 + $1.size }).formatted(.byteCount(style: .file)))")
                    .font(.headline)
                    .monospacedDigit()
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.thumbnailSize), spacing: 6), count: 6), spacing: 6) {
                    ForEach(items.prefix(Self.previewCount)) { item in
                        FileThumbnail(item: item, browser: browser, size: Self.thumbnailSize, pixels: Int(Self.thumbnailSize * 2))
                            .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
                            .clipped()
                    }
                }
            }
        } else {
            ProgressView("Looking for new photos…")
                .controlSize(.small)
        }
    }

    private var importTitle: String {
        guard let items, !items.isEmpty else {
            return String(localized: "Import")
        }
        return String(localized: "Import \(items.count) Items")
    }

    private func scan() async {
        guard let device = browser.device, let storages = app.storages[device.id] else {
            return
        }
        do {
            items = try await app.photoImport.scan(deviceID: device.id, storages: storages)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = destination
        if panel.runModal() == .OK, let url = panel.url {
            destination = url
        }
    }

    private func startImport() {
        guard let items, let device = browser.device else {
            return
        }
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        app.importPhotos(items, from: device, to: destination)
        dismiss()
    }
}
