import Foundation

/// Name and Android version read with one `getprop` call.
/// `getprop` prints an empty line for an unset property, so lines stay in order:
///
///     Pixel 11 Pro     ro.product.marketname  (unset on many phones)
///     Pixel 11 Pro     ro.product.model
///     17               ro.build.version.release
struct DeviceDetails: Sendable, Equatable {
    static let command = "getprop ro.product.marketname; getprop ro.product.model; getprop ro.build.version.release"

    private enum Line: Int {
        case marketName
        case model
        case androidVersion
    }

    let name: String
    let androidVersion: String?

    init(name: String, androidVersion: String?) {
        self.name = name
        self.androidVersion = androidVersion
    }

    init(getpropOutput: String, fallbackName: String) {
        let lines = getpropOutput
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        func value(_ line: Line) -> String? {
            guard line.rawValue < lines.count, !lines[line.rawValue].isEmpty else {
                return nil
            }
            return lines[line.rawValue]
        }
        name = value(.marketName) ?? value(.model) ?? fallbackName
        androidVersion = value(.androidVersion)
    }
}
