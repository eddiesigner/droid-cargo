import AppKit
import CargoServices
import SwiftUI

/// Opens the Connection Help window. Built on an AppKit tab controller in
/// toolbar style, the same look as the Settings window: SwiftUI only gives
/// that style to the Settings scene.
@MainActor
enum ConnectionHelp {
    /// Set once at launch; the window reads app state through it.
    static weak var app: AppModel?

    private static let contentSize = NSSize(width: 560, height: 520)
    private static let frameName = "ConnectionHelp"
    private static var controller: NSWindowController?

    static func show() {
        if let window = controller?.window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let app else {
            return
        }

        let window = NSWindow(contentViewController: HelpTabController(app: app, size: contentSize))
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        if !window.setFrameUsingName(frameName) {
            window.center()
        }
        window.setFrameAutosaveName(frameName)

        let controller = NSWindowController(window: window)
        controller.showWindow(nil)
        self.controller = controller
    }
}

private enum HelpTab: Int, CaseIterable {
    case status
    case setup
    case problems

    var title: String {
        switch self {
        case .status: String(localized: "Status")
        case .setup: String(localized: "Setup")
        case .problems: String(localized: "Troubleshooting")
        }
    }

    var symbol: String {
        switch self {
        case .status: "checkmark.circle"
        case .setup: "list.number"
        case .problems: "wrench.and.screwdriver"
        }
    }
}

/// Shared by the tabs so Status can jump to a fix in Problems.
@Observable
private final class HelpNavigation {
    var tab = HelpTab.status
    /// Problems the user opened, or that Status jumped to.
    var expanded: Set<Problem> = []

    func show(_ problem: Problem) {
        expanded.insert(problem)
        tab = .problems
    }
}

/// Toolbar tabs; the window title follows the selected tab, like Settings.
private final class HelpTabController: NSTabViewController {
    private let navigation = HelpNavigation()

    init(app: AppModel, size: NSSize) {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        for tab in HelpTab.allCases {
            let page = NSHostingController(rootView: page(tab, app: app).frame(width: size.width, height: size.height))
            page.title = tab.title
            // Lets the tab controller size the window to the page, like Settings.
            page.sizingOptions = .preferredContentSize
            let item = NSTabViewItem(viewController: page)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil)
            addTabViewItem(item)
        }
        followNavigation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @ViewBuilder
    private func page(_ tab: HelpTab, app: AppModel) -> some View {
        switch tab {
        case .status:
            StatusTab(app: app, showProblem: navigation.show)
        case .setup:
            SetupTab(isADBInstalled: app.devices.isADBInstalled)
        case .problems:
            ProblemsTab(navigation: navigation)
        }
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let tab = HelpTab(rawValue: selectedTabViewItemIndex), tab != navigation.tab {
            navigation.tab = tab
        }
    }

    /// Selects the tab the navigation model asks for (e.g. after How to Fix).
    private func followNavigation() {
        withObservationTracking {
            _ = navigation.tab
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else {
                    return
                }
                if self.selectedTabViewItemIndex != self.navigation.tab.rawValue {
                    self.selectedTabViewItemIndex = self.navigation.tab.rawValue
                }
                self.followNavigation()
            }
        }
    }
}

// MARK: - Status

private struct StatusTab: View {
    let app: AppModel
    let showProblem: (Problem) -> Void

    var body: some View {
        Form {
            PlatformToolsSection(app: app)

            if app.devices.devices.isEmpty {
                NoPhonesSection(showProblem: showProblem)
            }
            ForEach(app.devices.devices) { device in
                PhoneSection(device: device, storages: app.storages[device.id] ?? [], showProblem: showProblem)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PlatformToolsSection: View {
    let app: AppModel

    var body: some View {
        Section("Android Platform Tools") {
            if let adb = app.devices.adbURL {
                LabeledContent("Status") {
                    StatusLabel(text: "Installed", kind: .good)
                }
                LabeledContent("Location") {
                    HStack(spacing: 4) {
                        Text(NSString(string: adb.path).abbreviatingWithTildeInPath)
                            .truncationMode(.middle)
                            .lineLimit(1)
                            .textSelection(.enabled)
                        Button("Show in Finder", systemImage: "magnifyingglass.circle") {
                            NSWorkspace.shared.activateFileViewerSelecting([adb])
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.hoverIcon)
                        .help("Show in Finder")
                    }
                }
            } else {
                LabeledContent("Status") {
                    StatusLabel(text: "Not installed", kind: .warning)
                }
                installRow
            }
        }
    }

    @ViewBuilder
    private var installRow: some View {
        switch app.devices.toolsInstall {
        case .idle:
            installButton("Install Platform Tools")
        case .downloading(let fraction):
            ProgressView("Downloading…", value: fraction)
        case .unpacking:
            ProgressView("Installing…")
                .progressViewStyle(.linear)
        case .failed(let message):
            Text(message).foregroundStyle(.secondary)
            installButton("Try Again")
        }
    }

    private func installButton(_ title: LocalizedStringKey) -> some View {
        LabeledContent("Downloads about 16 MB from Google.") {
            Button(title, action: app.installPlatformTools)
        }
    }
}

private struct NoPhonesSection: View {
    let showProblem: (Problem) -> Void

    var body: some View {
        Section("Phones") {
            LabeledContent("Status") {
                StatusLabel(text: "None detected", kind: .warning)
            }
            LabeledContent {
                Button("How to Fix") { showProblem(.notDetected) }
            } label: {
                Text("Unlock the phone, check that USB debugging is on, and set the USB mode to “File transfer / Android Auto”.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PhoneSection: View {
    let device: Device
    let storages: [Storage]
    let showProblem: (Problem) -> Void

    var body: some View {
        Section(device.name) {
            LabeledContent("Status") {
                StatusLabel(text: device.state.statusText, kind: device.state.statusKind)
            }
            if let hint = device.state.hint {
                LabeledContent {
                    if let problem = device.state.problem {
                        Button("How to Fix") { showProblem(problem) }
                    }
                } label: {
                    Text(hint)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            LabeledContent("Model", value: device.model)
            LabeledContent("Serial Number") {
                Text(device.id).textSelection(.enabled)
            }
            LabeledContent("Connection", value: String(localized: "USB debugging"))
            ForEach(storages) { storage in
                LabeledContent(storage.name) {
                    Text("\(Int64(storage.freeBytes).formatted(.byteCount(style: .file))) available of \(Int64(storage.totalBytes).formatted(.byteCount(style: .file)))")
                        .monospacedDigit()
                }
            }
        }
    }
}

/// Icon plus text; the icon carries the color so the text stays readable.
private struct StatusLabel: View {
    enum Kind {
        case good
        case warning
        case neutral
    }

    let text: LocalizedStringKey
    let kind: Kind

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
    }

    private var symbol: String {
        switch kind {
        case .good: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .neutral: "minus.circle.fill"
        }
    }

    private var color: AnyShapeStyle {
        switch kind {
        case .good: AnyShapeStyle(.tint)
        case .warning: AnyShapeStyle(.orange)
        case .neutral: AnyShapeStyle(.secondary)
        }
    }
}

private extension DeviceState {
    var statusText: LocalizedStringKey {
        switch self {
        case .online: "Connected"
        case .unauthorized: "Waiting for permission"
        case .offline: "Offline"
        case .unsupported(let reason): LocalizedStringKey(reason)
        }
    }

    var statusKind: StatusLabel.Kind {
        switch self {
        case .online: .good
        case .unauthorized, .unsupported: .warning
        case .offline: .neutral
        }
    }

    /// What to do next, when there is something to do.
    var hint: LocalizedStringKey? {
        switch self {
        case .online: nil
        case .unauthorized: "Unlock the phone and tap Allow on the “Allow USB debugging?” prompt."
        case .offline: "Unplug the phone and plug it back in."
        case .unsupported: "This phone can’t be used over USB debugging."
        }
    }

    var problem: Problem? {
        switch self {
        case .online, .unsupported: nil
        case .unauthorized: .waitingForPermission
        case .offline: .offline
        }
    }
}

// MARK: - Setup

private struct SetupTab: View {
    let isADBInstalled: Bool

    var body: some View {
        Form {
            Section {
                if !isADBInstalled {
                    SetupStepCard(step: .installTools, number: nil, style: .formRow)
                }
                ForEach(Array(SetupStep.phoneSteps.enumerated()), id: \.element) { index, step in
                    SetupStepCard(step: step, number: index + 1, style: .formRow)
                }
            } footer: {
                Text("You only need to do this once per phone.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Problems

private struct ProblemsTab: View {
    let navigation: HelpNavigation

    var body: some View {
        Form {
            Section {
                ForEach(Problem.allCases) { problem in
                    ProblemRow(problem: problem, isExpanded: isExpanded(problem))
                }
            }
        }
        .formStyle(.grouped)
    }

    private func isExpanded(_ problem: Problem) -> Binding<Bool> {
        Binding {
            navigation.expanded.contains(problem)
        } set: { isOpen in
            if isOpen {
                navigation.expanded.insert(problem)
            } else {
                navigation.expanded.remove(problem)
            }
        }
    }
}

/// A disclosure row whose whole title toggles it (DisclosureGroup only
/// reacts to its chevron). Fixes indent by the chevron's width so they line
/// up with the title text.
private struct ProblemRow: View {
    private static let chevronWidth: CGFloat = 12
    private static let gap: CGFloat = 6
    private static let bulletSize: CGFloat = 5
    private static let bulletBaseline: CGFloat = 7

    let problem: Problem
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: Self.gap) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: Self.chevronWidth)
                    Text(problem.title)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))

            if isExpanded {
                fixes
                    .padding(.leading, Self.chevronWidth + Self.gap)
            }
        }
        .padding(.vertical, 2)
    }

    private var fixes: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(problem.fixes.indices, id: \.self) { index in
                // A neutral bullet: checkmarks read as to-dos.
                HStack(alignment: .firstTextBaseline, spacing: Self.gap) {
                    Circle()
                        .frame(width: Self.bulletSize, height: Self.bulletSize)
                        .alignmentGuide(.firstTextBaseline) { _ in Self.bulletBaseline }
                    Text(problem.fixes[index])
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let code = problem.code {
                CodeLine(code: code)
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Common connection problems and what fixes them.
private enum Problem: CaseIterable, Identifiable {
    case notDetected
    case waitingForPermission
    case offline
    case slowOrDropping
    case toolsMissing

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .notDetected: "My phone doesn’t appear"
        case .waitingForPermission: "Stuck on “Waiting for permission”"
        case .offline: "My phone shows as Offline"
        case .slowOrDropping: "Transfers are slow or keep disconnecting"
        case .toolsMissing: "Platform Tools aren’t found"
        }
    }

    var fixes: [LocalizedStringKey] {
        switch self {
        case .notDetected:
            [
                "Set the USB mode to “File transfer / Android Auto”. Charging-only mode hides the phone.",
                "Check that USB debugging is on in Developer options.",
                "Use a data cable. Some cables only charge.",
                "Plug straight into the Mac instead of a hub, or try another port.",
                "Turn USB debugging off and on again, then reconnect.",
            ]
        case .waitingForPermission:
            [
                "Unlock the phone. The Allow prompt only shows on an unlocked screen.",
                "No prompt? In Developer options, tap Revoke USB debugging authorizations, then unplug and reconnect.",
            ]
        case .offline:
            [
                "Unplug the phone and plug it back in.",
                "If it stays offline, restart the phone.",
            ]
        case .slowOrDropping:
            [
                "Use a USB 3 (USB-C to USB-C) cable plugged directly into the Mac. Hubs and USB 2 cables cap speed.",
                "Transfers resume on their own if the cable briefly disconnects.",
            ]
        case .toolsMissing:
            [
                "Open the Status tab and click Install Platform Tools.",
                "Installed elsewhere? Set the adb path in Settings › Advanced.",
                "Prefer Homebrew? Run this, then relaunch DroidCargo:",
            ]
        }
    }

    var code: String? {
        self == .toolsMissing ? SetupStep.homebrewCommand : nil
    }
}

/// Help menu entry that opens the Connection Help window.
struct HelpCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Connection Help") { ConnectionHelp.show() }
                .keyboardShortcut("?", modifiers: .command)
        }
    }
}

/// Opens Connection Help from inside a window.
struct ConnectionHelpButton: View {
    var body: some View {
        Button("Connection Help…") { ConnectionHelp.show() }
    }
}
