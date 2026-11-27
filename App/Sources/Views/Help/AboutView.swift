import SwiftUI

enum AboutWindow {
    static let id = "about"
    static let authorName = "Eduardo Gómez"
    static let authorURL = URL(string: "https://eddiesigner.com")!
    static let iconSize: CGFloat = 96
    static let width: CGFloat = 300
}

/// Icon, name and version like the standard About panel, plus credits.
struct AboutView: View {
    @Environment(\.openURL) private var openURL

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: AboutWindow.iconSize, height: AboutWindow.iconSize)
                .accessibilityHidden(true)
            Text(verbatim: "DroidCargo")
                .font(.title2.bold())
            Text("Version \(version)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            // Credits: the name links to the author's site.
            HStack(spacing: 4) {
                Text("Crafted with ❤️ by")
                Button { openURL(AboutWindow.authorURL) } label: { Text(verbatim: AboutWindow.authorName) }
                    .buttonStyle(.hoverLink)
            }
            .padding(.top, 12)
            SupportNote()
        }
        .font(.callout)
        .padding(24)
        .frame(width: AboutWindow.width)
    }
}
