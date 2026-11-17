import CargoServices
import SwiftUI

struct InspectorView: View {
    let browser: BrowserModel
    private static let previewSize: CGFloat = 220

    var body: some View {
        let selected = browser.selectedItems
        Group {
            if selected.count == 1, let item = selected.first {
                details(item)
            } else if selected.count > 1 {
                ContentUnavailableView(
                    "\(selected.count) Items",
                    systemImage: "square.stack",
                    description: Text(Int64(selected.reduce(0) { $0 + $1.size }).formatted(.byteCount(style: .file)))
                )
            } else if let storage = browser.storage {
                StorageSummary(storage: storage)
            } else {
                ContentUnavailableView("No Selection", systemImage: "info.circle", description: Text("Select an item to see its details."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func details(_ item: RemoteItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FileThumbnail(item: item, browser: browser, size: Self.previewSize, pixels: Int(Self.previewSize * 2))
                    .frame(maxWidth: .infinity)

                Text(item.name)
                    .font(.headline)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    row("Kind", FileCategory.kindDescription(for: item))
                    if !item.isDirectory {
                        row("Size", "\(Int64(item.size).formatted(.byteCount(style: .file))) (\(item.size.formatted()) bytes)")
                    }
                    row("Modified", item.modified.formatted(date: .long, time: .shortened))
                    row("Where", RemotePath.parent(item.path))
                }
                .font(.callout)

                HStack {
                    Button("Download") { browser.download([item]) }
                        .buttonStyle(.borderedProminent)
                        .hoverHighlight()
                    if !item.isDirectory {
                        Button("Quick Look") { Task { await browser.toggleQuickLook() } }
                    }
                }
            }
            .padding()
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Capacity of the current storage, like a volume's Get Info.
private struct StorageSummary: View {
    let storage: Storage

    private var fraction: Double {
        storage.totalBytes == 0 ? 0 : Double(storage.usedBytes) / Double(storage.totalBytes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(storage.name, systemImage: storage.kind == .internalStorage ? "internaldrive" : "sdcard")
                .font(.headline)
            Gauge(value: fraction) {
                EmptyView()
            }
            .gaugeStyle(.linearCapacity)
            .tint(fraction > 0.9 ? .orange : .accentColor)
            .accessibilityLabel("Used space")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Used").foregroundStyle(.secondary)
                    Text(Int64(storage.usedBytes).formatted(.byteCount(style: .file)))
                }
                GridRow {
                    Text("Available").foregroundStyle(.secondary)
                    Text(Int64(storage.freeBytes).formatted(.byteCount(style: .file)))
                }
                GridRow {
                    Text("Capacity").foregroundStyle(.secondary)
                    Text(Int64(storage.totalBytes).formatted(.byteCount(style: .file)))
                }
            }
            .font(.callout)
            .monospacedDigit()
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
