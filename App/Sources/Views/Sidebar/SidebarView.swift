import AppKit
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
        .scrollContentBackground(.hidden)
        .background(SidebarBackdrop().ignoresSafeArea())
        .overlay {
            if app.devices.devices.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "cable.connector")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No Phones Connected")
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

/// Lets more of the desktop show through than the default sidebar material.
private struct SidebarBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Finder-style header: just the name. Readiness shows in the rows below it.
private struct DeviceHeader: View {
    let device: Device

    var body: some View {
        Text(device.name)
    }
}

private struct StorageRow: View {
    let storage: Storage

    var body: some View {
        Label(storage.name, systemImage: storage.kind == .internalStorage ? "internaldrive" : "sdcard")
    }
}
