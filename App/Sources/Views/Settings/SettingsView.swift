import CargoServices
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let app: AppModel

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings(settings: settings)
            }
            Tab("Transfers", systemImage: "arrow.up.arrow.down") {
                TransferSettings(settings: settings)
            }
            Tab("Advanced", systemImage: "wrench.and.screwdriver") {
                AdvancedSettings(settings: settings, app: app)
            }
        }
        .frame(width: 500)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            LabeledContent("Download to") {
                HStack {
                    Label(settings.downloadFolder.lastPathComponent, systemImage: "folder")
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.canCreateDirectories = true
                        panel.directoryURL = settings.downloadFolder
                        if panel.runModal() == .OK, let url = panel.url {
                            settings.downloadFolder = url
                        }
                    }
                }
            }
            Toggle("Show downloaded files in Finder", isOn: $settings.revealAfterDownload)
            Toggle("Notify me when transfers finish in the background", isOn: $settings.notifyWhenDone)
            Toggle("Show hidden files", isOn: $settings.showHiddenFiles)
        }
        .formStyle(.grouped)
    }
}

private struct TransferSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Picker("When a file already exists", selection: $settings.conflictPolicy) {
                Text("Ask Me").tag(ConflictPolicy.ask)
                Text("Keep Both").tag(ConflictPolicy.keepBoth)
                Text("Replace").tag(ConflictPolicy.replace)
                Text("Skip").tag(ConflictPolicy.skip)
            }
            Section {
                Stepper(value: $settings.parallelTransfers, in: AppSettings.parallelRange) {
                    LabeledContent("Files at the same time", value: settings.parallelTransfers.formatted())
                }
            } footer: {
                Text("Copying a few files at once is faster for many small photos. Use 1 for older phones.")
            }
            Section {
                Toggle("Add uploaded photos and music to the phone’s library", isOn: $settings.scanMedia)
            } footer: {
                Text("Makes uploads appear in Gallery and music apps right away.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AdvancedSettings: View {
    @Bindable var settings: AppSettings
    let app: AppModel
    @State private var cacheCleared = false

    var body: some View {
        Form {
            Section {
                TextField("adb location", text: $settings.customADBPath, prompt: Text("Automatic"))
            } header: {
                Text("Android Platform Tools")
            } footer: {
                Text("Leave empty to find adb automatically (Homebrew or Android Studio).")
            }
            Section("Cache") {
                LabeledContent("Thumbnails and previews") {
                    Button(cacheCleared ? "Cleared" : "Clear Cache") {
                        Task {
                            await app.clearCaches()
                            cacheCleared = true
                        }
                    }
                    .disabled(cacheCleared)
                }
            }
        }
        .formStyle(.grouped)
    }
}
