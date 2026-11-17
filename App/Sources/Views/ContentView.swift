import CargoServices
import SwiftUI

struct ContentView: View {
    let app: AppModel
    @State private var browser: BrowserModel
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    init(app: AppModel) {
        self.app = app
        _browser = State(initialValue: BrowserModel(app: app))
    }

    var body: some View {
        // First launch, or adb went missing: get Platform Tools sorted before anything else.
        if app.devices.isADBInstalled && app.settings.hasCompletedWelcome {
            browserWindow
        } else {
            WelcomeView(app: app)
        }
    }

    private var browserWindow: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(app: app, browser: browser)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            detail
        }
        .inspector(isPresented: $browser.isInspectorShown) {
            InspectorView(browser: browser)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
        }
        .focusedSceneValue(\.browser, browser)
        .sheet(item: Binding(get: { app.conflictPrompt }, set: { _ in })) { prompt in
            ConflictSheet(prompt: prompt)
        }
        .onChange(of: app.storages) { browser.selectDefaultIfNeeded() }
        .onAppear { browser.selectDefaultIfNeeded() }
    }

    @ViewBuilder
    private var detail: some View {
        if let device = browser.device, device.state == .online, browser.currentPath != nil {
            BrowserView(browser: browser)
        } else if let device = app.devices.devices.first(where: { $0.state == .unauthorized }) {
            AuthorizationView(device: device)
        } else if app.onlineDevices.isEmpty {
            OnboardingView(isADBInstalled: app.devices.isADBInstalled)
        } else {
            ContentUnavailableView("Choose a Location", systemImage: "sidebar.left", description: Text("Select a storage in the sidebar."))
        }
    }
}
