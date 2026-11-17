import CargoServices
import SwiftUI

struct SidebarView: View {
    let app: AppModel
    @Bindable var browser: BrowserModel

    var body: some View {
        List(selection: $browser.sidebarSelection) {
            ForEach(app.devices.devices) { device in
                Section {
                    deviceContent(device)
                } header: {
                    DeviceHeader(device: device)
                }
            }

            if let deviceID = browser.deviceID, let favorites = app.settings.favorites[deviceID], !favorites.isEmpty {
                Section("Favorites") {
                    ForEach(favorites, id: \.self) { path in
                        Label(RemotePath.name(path), systemImage: "folder")
                            .tag(SidebarSelection.favorite(deviceID: deviceID, path: path))
                            .contextMenu {
                                Button("Remove from Favorites") { app.settings.toggleFavorite(path, deviceID: deviceID) }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if app.devices.devices.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "cable.connector")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No Phones")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private func deviceContent(_ device: Device) -> some View {
        switch device.state {
        case .online:
            if let storages = app.storages[device.id] {
                ForEach(storages) { storage in
                    StorageRow(storage: storage)
                        .tag(SidebarSelection.storage(deviceID: device.id, rootPath: storage.rootPath))
                }
            } else if let error = app.storageErrors[device.id] {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Connecting…").foregroundStyle(.secondary)
                }
            }
        case .unauthorized:
            Label("Waiting for permission", systemImage: "lock")
                .foregroundStyle(.secondary)
        case .offline:
            Label("Offline", systemImage: "bolt.horizontal.circle")
                .foregroundStyle(.secondary)
        case .unsupported(let reason):
            Label(reason, systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
    }
}

private struct DeviceHeader: View {
    let device: Device

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "smartphone")
            Text(device.name)
            Circle()
                .fill(device.state == .online ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(device.state == .online ? Text("Connected") : Text("Not ready"))
    }
}

/// Storage name with a thin capacity bar, like Finder's sidebar volumes.
private struct StorageRow: View {
    let storage: Storage

    private var fraction: Double {
        storage.totalBytes == 0 ? 0 : Double(storage.usedBytes) / Double(storage.totalBytes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(storage.name, systemImage: storage.kind == .internalStorage ? "internaldrive" : "sdcard")
            if storage.totalBytes > 0 {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
                    .tint(fraction > 0.9 ? .orange : .accentColor)
                    .padding(.leading, 24)
                Text("\(Int64(storage.freeBytes).formatted(.byteCount(style: .file))) available")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.leading, 24)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
