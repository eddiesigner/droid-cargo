import AppKit
import SwiftUI

/// The steps that get a phone talking to DroidCargo. Shared by onboarding
/// and Connection Help so both always say the same thing.
enum SetupStep: Int, CaseIterable, Identifiable {
    case installTools
    case developerOptions
    case usbDebugging
    case fileTransferMode
    case allowMac

    static let homebrewCommand = "brew install android-platform-tools"

    /// Steps done on the phone, in order. Installing tools is conditional.
    static let phoneSteps: [SetupStep] = [.developerOptions, .usbDebugging, .fileTransferMode, .allowMac]

    var id: Int { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .installTools: "Install Android Platform Tools"
        case .developerOptions: "Turn on Developer Options"
        case .usbDebugging: "Turn on USB Debugging"
        case .fileTransferMode: "Choose File Transfer"
        case .allowMac: "Allow This Mac"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .installTools:
            "DroidCargo uses Google’s adb to talk to your phone. Click Install Platform Tools in the Status tab, or run this in Terminal:"
        case .developerOptions:
            "On the phone, open Settings › About phone and tap Build number seven times."
        case .usbDebugging:
            "Open Settings › System › Developer options and switch on USB debugging."
        case .fileTransferMode:
            "Plug in the phone, tap the USB notification, and choose “File transfer / Android Auto”."
        case .allowMac:
            "Unlock the phone and tap Allow. Check “Always allow from this computer” to skip this next time."
        }
    }

    var code: String? {
        self == .installTools ? Self.homebrewCommand : nil
    }
}

/// One numbered step: a standalone card, or a plain row inside a Form.
struct SetupStepCard: View {
    enum Style {
        case card
        case formRow
    }

    let step: SetupStep
    let number: Int?
    var style: Style = .card

    private static let badgeSize: CGFloat = 26
    private static let maxWidth: CGFloat = 460

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number.map { "\($0)" } ?? "!")
                .font(.callout.bold())
                .frame(width: Self.badgeSize, height: Self.badgeSize)
                .background(.tint.opacity(0.15), in: .circle)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(step.title).font(.headline)
                Text(step.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let code = step.code {
                    CodeLine(code: code)
                }
            }
        }
        .modifier(StepChrome(style: style, maxWidth: Self.maxWidth))
        .accessibilityElement(children: .combine)
    }
}

/// Card background only when standing alone; Form rows bring their own.
private struct StepChrome: ViewModifier {
    let style: SetupStepCard.Style
    let maxWidth: CGFloat

    func body(content: Content) -> some View {
        switch style {
        case .card:
            content
                .padding(16)
                .frame(maxWidth: maxWidth, alignment: .leading)
                .background(.background.secondary, in: .rect(cornerRadius: 14))
        case .formRow:
            content
                .padding(.vertical, 4)
        }
    }
}

/// A Terminal command with a copy button.
struct CodeLine: View {
    let code: String

    var body: some View {
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
            .help("Copy")
            .buttonStyle(.hoverIcon)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }
}
