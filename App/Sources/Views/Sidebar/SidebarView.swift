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

/// Finder-style header: the name, then Android version and USB speed.
/// Readiness shows in the rows below it.
private struct DeviceHeader: View {
    let device: Device

    /// "Android 17 · USB 2"; empty until the phone allows access.
    private var details: String {
        var parts: [String] = []
        if let version = device.androidVersion {
            parts.append(String(localized: "Android \(version)"))
        }
        if let speed = device.usbSpeed {
            parts.append(speed.title)
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(device.name)
            if !details.isEmpty {
                Text(details)
                    .font(.caption)
                    .fontWeight(.regular)
                    .foregroundStyle(.tertiary)
                    .help(device.usbSpeed?.help ?? "")
            }
        }
    }
}

/// Storage name over a thin capacity bar and free space, like Finder's volume info.
private struct StorageRow: View {
    let storage: Storage

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(storage.name)
                CapacityBar(storage: storage)
                Text("\(Int64(storage.freeBytes).formatted(.byteCount(style: .file))) free")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
            .help("\(Int64(storage.freeBytes).formatted(.byteCount(style: .file))) available of \(Int64(storage.totalBytes).formatted(.byteCount(style: .file)))")
        } icon: {
            Image(systemName: storage.kind == .internalStorage ? "internaldrive" : "sdcard")
        }
    }
}

/// A 4 pt bar. Accent when idle, white on the selected (accent) row, orange when nearly full.
private struct CapacityBar: View {
    private static let height: CGFloat = 4
    private static let nearlyFull = 0.9

    let storage: Storage
    @Environment(\.backgroundProminence) private var prominence

    private var fraction: Double {
        storage.totalBytes == 0 ? 0 : Double(storage.usedBytes) / Double(storage.totalBytes)
    }

    private var fill: Color {
        if prominence == .increased {
            return .white
        }
        return fraction > Self.nearlyFull ? .orange : .accentColor
    }

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(fill)
                        .frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: Self.height)
            .accessibilityElement()
            .accessibilityLabel("Used space")
            .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
    }
}

private extension USBSpeed {
    var title: String {
        switch self {
        case .usb1: "USB 1"
        case .usb2: "USB 2"
        case .usb3: "USB 3"
        case .usb3Fast: "USB 3.2"
        }
    }

    /// Slow links explain themselves; fast ones need no tooltip.
    var help: String {
        switch self {
        case .usb1, .usb2: String(localized: "Connected at USB 2 speed or slower. A USB 3 cable plugged straight into the Mac copies much faster.")
        case .usb3, .usb3Fast: ""
        }
    }
}
