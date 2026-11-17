import CargoServices
import SwiftUI

@main
struct DroidCargoApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(app: app)
                .frame(minWidth: 760, minHeight: 460)
                .onAppear { app.requestNotificationPermission() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            BrowserCommands()
            SidebarCommands()
            InspectorCommands()
        }

        Settings {
            SettingsView(settings: app.settings, app: app)
        }
    }
}

/// Lets menu commands reach the focused window's browser.
struct FocusedBrowserKey: FocusedValueKey {
    typealias Value = BrowserModel
}

extension FocusedValues {
    var browser: BrowserModel? {
        get { self[FocusedBrowserKey.self] }
        set { self[FocusedBrowserKey.self] = newValue }
    }
}

struct BrowserCommands: Commands {
    @FocusedValue(\.browser) private var browser

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Upload Files…") { browser?.requestUpload() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(browser?.device == nil)
            Button("Import Photos & Videos…") { browser?.isPhotoImportShown = true }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(browser?.device == nil)
        }

        CommandMenu("Go") {
            Button("Back") { browser?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!(browser?.canGoBack ?? false))
            Button("Forward") { browser?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!(browser?.canGoForward ?? false))
            Button("Enclosing Folder") { browser?.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!(browser?.canGoUp ?? false))
            Divider()
            Button("Refresh") { browser?.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(browser?.currentPath == nil)
        }

        CommandGroup(before: .toolbar) {
            Button("as List") { browser?.app.settings.layout = .list }
                .keyboardShortcut("1", modifiers: .command)
            Button("as Grid") { browser?.app.settings.layout = .grid }
                .keyboardShortcut("2", modifiers: .command)
            Divider()
            Button(browser?.app.settings.showHiddenFiles == true ? "Hide Hidden Files" : "Show Hidden Files") {
                browser?.app.settings.showHiddenFiles.toggle()
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
            Divider()
        }
    }
}
