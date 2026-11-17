import AppKit
import CargoServices
import SwiftUI

/// First launch: makes sure Platform Tools are present. One button installs
/// them if missing; once found, Get Started opens the browser.
struct WelcomeView: View {
    let app: AppModel
    @Environment(\.openURL) private var openURL

    private static let iconSize: CGFloat = 96
    private static let contentWidth: CGFloat = 400
    private static let buttonWidth: CGFloat = 240
    private static let controlHeight: CGFloat = 64
    private static let foundSymbol = "checkmark.circle.fill"

    private var state: ToolsInstallState {
        app.devices.toolsInstall
    }

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: Self.iconSize, height: Self.iconSize)
                    .accessibilityHidden(true)
                Text("Welcome to DroidCargo")
                    .font(.largeTitle.bold())
                Text(foundADB == nil
                     ? "To talk to Android phones, DroidCargo uses Android Platform Tools, free software from Google. Installing it takes a few seconds."
                     : "To talk to Android phones, DroidCargo uses Android Platform Tools, free software from Google.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Fixed height so swapping button and progress bar doesn't shift the layout.
            installControl
                .frame(width: Self.buttonWidth, height: Self.controlHeight)

            if let adb = foundADB {
                foundNote(adb)
            } else {
                installNotes
            }
        }
        .frame(width: Self.contentWidth)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The adb DroidCargo will use, once one exists and no install is running.
    private var foundADB: URL? {
        isBusy ? nil : app.devices.adbURL
    }

    private func foundNote(_ adb: URL) -> some View {
        VStack(spacing: 6) {
            Label("Android Platform Tools are installed.", systemImage: Self.foundSymbol)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .tint)
            Text(NSString(string: adb.path).abbreviatingWithTildeInPath)
                .foregroundStyle(.secondary)
                .truncationMode(.middle)
                .lineLimit(1)
                .textSelection(.enabled)
            termsLine("Platform Tools are subject to the ")
        }
        .font(.footnote)
    }

    /// A real button, not an inline Markdown link, so it gets the hover cursor.
    private func termsLine(_ lead: LocalizedStringKey) -> some View {
        HStack(spacing: 0) {
            Text(lead)
                .foregroundStyle(.secondary)
            Button("Android SDK Terms") { openURL(DeviceService.platformToolsTermsURL) }
                .buttonStyle(.hoverLink)
            Text(".")
                .foregroundStyle(.secondary)
        }
    }

    private var installNotes: some View {
        VStack(spacing: 6) {
            Text("Downloads about 16 MB from Google.")
                .foregroundStyle(.secondary)
            termsLine("By installing, you agree to the ")
            Button("Already installed? Locate adb…", action: locateADB)
                .buttonStyle(.hoverLink)
                .disabled(isBusy)
        }
        .font(.footnote)
        .multilineTextAlignment(.center)
    }

    // MARK: Install button and progress

    @ViewBuilder
    private var installControl: some View {
        if foundADB != nil {
            primaryButton("Get Started") { app.settings.hasCompletedWelcome = true }
        } else {
            installProgress
        }
    }

    @ViewBuilder
    private var installProgress: some View {
        switch state {
        case .idle:
            installButton("Install Platform Tools")
        case .downloading(let fraction):
            ProgressView(value: fraction) {
                Text("Downloading…")
            } currentValueLabel: {
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
            }
        case .unpacking:
            ProgressView {
                Text("Installing…")
            }
            .progressViewStyle(.linear)
        case .failed(let message):
            VStack(spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                installButton("Try Again")
            }
        }
    }

    private func installButton(_ title: LocalizedStringKey) -> some View {
        primaryButton(title, action: app.installPlatformTools)
    }

    private func primaryButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .hoverHighlight()
        .keyboardShortcut(.defaultAction)
    }

    private var isBusy: Bool {
        switch state {
        case .downloading, .unpacking: true
        case .idle, .failed: false
        }
    }

    // MARK: Existing install

    private func locateADB() {
        let panel = NSOpenPanel()
        panel.message = String(localized: "Choose the adb program inside your platform-tools folder.")
        panel.prompt = String(localized: "Use adb")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        app.useADB(at: url)
    }
}
