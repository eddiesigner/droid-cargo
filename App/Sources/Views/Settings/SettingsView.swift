import CargoServices
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let app: AppModel

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings(settings: settings, app: app)
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
    let app: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $settings.language) {
                    Text("Automatic (\(AppLanguage.automatic.nativeName))").tag(AppLanguage.automatic)
                    Divider()
                    ForEach([AppLanguage.english, .spanish, .german], id: \.self) { language in
                        Text(verbatim: language.nativeName).tag(language)
                    }
                }
                // The language only changes at launch, so offer a restart when it differs.
                if settings.language.effective != AppLanguage.running {
                    LabeledContent {
                        Button("Restart Now", action: app.relaunch)
                    } label: {
                        Text("Restart DroidCargo to use \(settings.language.effective.nativeName).")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Automatic follows your Mac’s language, or English if it isn’t available.")
            }
            Section {
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
            } footer: {
                SupportNote()
                    .padding(.top)
            }
        }
        .formStyle(.grouped)
    }
}

private struct TransferSettings: View {
    @Bindable var settings: AppSettings

    /// Typed values outside the allowed range snap to the nearest end.
    private var parallelTransfers: Binding<Int> {
        Binding {
            settings.parallelTransfers
        } set: { value in
            settings.parallelTransfers = value.clamped(to: AppSettings.parallelRange)
        }
    }

    var body: some View {
        Form {
            Picker("When a file already exists", selection: $settings.conflictPolicy) {
                Text("Ask Me").tag(ConflictPolicy.ask)
                Text("Keep Both").tag(ConflictPolicy.keepBoth)
                Text("Replace").tag(ConflictPolicy.replace)
                Text("Skip").tag(ConflictPolicy.skip)
            }
            Section {
                Picker("Date of copied files", selection: $settings.fileDates) {
                    Text("Original Date").tag(FileDatePolicy.keepOriginal)
                    Text("Date Copied").tag(FileDatePolicy.useTransferDate)
                }
            } footer: {
                Text("Original Date keeps the date a file had before copying, such as when a photo was taken.")
            }
            Section {
                // Value in a field next to the arrows, like macOS's own number steppers.
                LabeledContent("Files to copy at once") {
                    HStack(spacing: 4) {
                        TextField("Files to copy at once", value: parallelTransfers, format: .number)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 40)
                        Stepper("Files to copy at once", value: parallelTransfers, in: AppSettings.parallelRange)
                            .labelsHidden()
                    }
                }
            } footer: {
                Text("Copying several files at once can speed up folders of small photos. Keep 1 for older phones.")
            }
            Section {
                Toggle("Add uploaded photos and music to the phone’s library", isOn: $settings.scanMedia)
            } footer: {
                Text("Makes uploads appear in Gallery and music apps right away.")
            }
        }
        .formStyle(.grouped)
        // Size the window to every row instead of scrolling the last one away.
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
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

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
