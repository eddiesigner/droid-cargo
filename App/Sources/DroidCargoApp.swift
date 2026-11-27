import CargoServices
import SwiftUI

@main
struct DroidCargoApp: App {
    @State private var app: AppModel

    init() {
        let app = AppModel()
        _app = State(initialValue: app)
        ConnectionHelp.app = app
    }

    var body: some Scene {
        WindowGroup {
            ContentView(app: app)
                .frame(minWidth: 760, minHeight: 460)
                .onAppear { app.requestNotificationPermission() }
        }
        // First launch only; afterwards macOS restores the user's size.
        // Tall enough to show all connection steps without scrolling.
        .defaultSize(width: 1100, height: 720)
        .windowToolbarStyle(.unified)
        .commands {
            BrowserCommands()
            SidebarCommands()
            HelpCommands()
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
            if let settings = browser?.app.settings {
                Menu("Sort By") {
                    SortMenuItems(settings: settings)
                }
            }
            // The info panel is a plain view, so the system Inspector command doesn't reach it.
            Button(browser?.isInspectorShown == true ? "Hide Inspector" : "Show Inspector") {
                browser?.isInspectorShown.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .control])
            .disabled(browser == nil)
            Divider()

        }
    }
}
