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
            SupportCommands()
        }

        Window("About DroidCargo", id: AboutWindow.id) {
            AboutView()
                .windowMinimizeBehavior(.disabled)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultPosition(.center)
        .commandsRemoved()

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

    private var hasSelectedFile: Bool {
        browser?.selectedItems.contains { !$0.isDirectory } ?? false
    }

    private func copyPath() {
        guard let item = browser?.singleSelection else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.path, forType: .string)
    }

    var body: some Commands {
        // Finder's shortcuts where Finder has the same action.
        CommandGroup(after: .newItem) {
            Button("New Folder") { browser?.isNewFolderShown = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(browser?.currentPath == nil)
            Divider()
            Button("Open") { browser?.openSelection() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(browser?.singleSelection == nil)
            Button("Quick Look") { Task { await browser?.toggleQuickLook() } }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(!hasSelectedFile)
            // Return renames in the file views; a menu shortcut would steal it from text fields.
            Button("Rename…") { browser?.renameSelection() }
                .disabled(browser?.singleSelection == nil)
            Divider()
            Button("Upload Files…") { browser?.requestUpload() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(browser?.device == nil)
            Button("Download") { browser?.download(browser?.selectedItems ?? []) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(browser?.selection.isEmpty ?? true)
            Button("Import Photos & Videos…") { browser?.isPhotoImportShown = true }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(browser?.device == nil)
        }

        CommandGroup(after: .pasteboard) {
            Button("Copy Path") { copyPath() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(browser?.singleSelection == nil)
            Divider()
            Button("Search This Folder") { browser?.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(browser?.currentPath == nil)
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
            // Safari's shortcut for its Downloads list.
            Button("Show Transfers") { browser?.app.isTransfersPopoverShown = true }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(browser == nil)
            Divider()

        }
    }
}
