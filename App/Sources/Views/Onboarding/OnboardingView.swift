import CargoServices
import SwiftUI

/// Shown when no phone is connected: how to get one ready.
struct OnboardingView: View {
    let isADBInstalled: Bool

    private static let homebrewCommand = "brew install android-platform-tools"

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 10) {
                    Image(systemName: "cable.connector.horizontal")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.tint)
                        .symbolEffect(.pulse, options: .repeating)
                        .accessibilityHidden(true)
                    Text("Connect Your Android Phone")
                        .font(.title.bold())
                    Text("Plug it in with a USB cable. DroidCargo finds it automatically.")
                        .foregroundStyle(.secondary)
                }

                if !isADBInstalled {
                    setupCard(
                        number: 0,
                        title: "Install Android Platform Tools",
                        detail: "DroidCargo uses Google’s adb to talk to your phone. Run this in Terminal:",
                        code: Self.homebrewCommand
                    )
                }

                VStack(alignment: .leading, spacing: 14) {
                    setupCard(number: 1, title: "Turn on Developer Options", detail: "On the phone, open Settings › About phone and tap Build number seven times.")
                    setupCard(number: 2, title: "Turn on USB Debugging", detail: "Open Settings › System › Developer options and switch on USB debugging.")
                    setupCard(number: 3, title: "Allow This Mac", detail: "Connect the cable and tap Allow on the phone. Check “Always allow from this computer” to skip this next time.")
                }
                .frame(maxWidth: 460)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }

    private func setupCard(number: Int, title: LocalizedStringKey, detail: LocalizedStringKey, code: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number == 0 ? "!" : "\(number)")
                .font(.callout.bold())
                .frame(width: 26, height: 26)
                .background(.tint.opacity(0.15), in: .circle)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let code {
                    HStack {
                        Text(code)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                        Spacer()
                        Button("Copy", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 460, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

/// Shown while the phone waits for the "Allow USB debugging?" tap.
struct AuthorizationView: View {
    let device: Device

    var body: some View {
        ContentUnavailableView {
            Label {
                Text("Unlock \(device.name) and Tap Allow")
            } icon: {
                Image(systemName: "lock.iphone")
                    .symbolEffect(.pulse, options: .repeating)
            }
        } description: {
            Text("Your phone is asking whether to trust this Mac. Choose “Always allow from this computer” so you only do this once.")
        }
    }
}
