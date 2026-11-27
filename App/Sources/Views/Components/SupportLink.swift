import SwiftUI

/// Donation page for people who want to support DroidCargo.
enum SupportLink {
    static let url = URL(string: "https://ko-fi.com/eddiesigner")!
}

/// About and Support entries at the top of the app menu.
/// About opens DroidCargo's own window: the standard panel can't color
/// its links with the app accent.
struct SupportCommands: Commands {
    @Environment(\.openURL) private var openURL
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About DroidCargo") { openWindow(id: AboutWindow.id) }
            Button("Support DroidCargo") { openURL(SupportLink.url) }
        }
    }
}

/// One quiet line for a settings footer or the About window.
struct SupportNote: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 4) {
            Text("Enjoying DroidCargo?")
            Button("Support it on Ko-fi") { openURL(SupportLink.url) }
                .buttonStyle(.hoverLink)
        }
    }
}
