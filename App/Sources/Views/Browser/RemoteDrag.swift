import AppKit
import CargoServices
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// A phone item dragged inside DroidCargo: its device and path.
    nonisolated static let remoteItem = NSPasteboard.PasteboardType("app.droidcargo.remote-item")
}

/// Drag item for a phone file. Finder gets a file promise (it copies the
/// file to the Mac); DroidCargo reads the phone path, so a drop on a folder
/// moves the item on the phone instead, or copies it with Option held.
nonisolated final class RemoteItemDragProvider: NSFilePromiseProvider {
    private enum Key {
        static let device = "device"
        static let path = "path"
    }

    private var payload: [String: String] = [:]

    @MainActor convenience init(item: RemoteItem, deviceID: String?, delegate: any NSFilePromiseProviderDelegate) {
        let type = item.isDirectory ? UTType.folder : (UTType(filenameExtension: item.fileExtension) ?? .data)
        self.init(fileType: type.identifier, delegate: delegate)
        userInfo = item
        payload = [Key.device: deviceID ?? "", Key.path: item.path]
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.remoteItem]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == .remoteItem ? payload : super.pasteboardPropertyList(forType: type)
    }

    /// Paths of phone items dragged from DroidCargo, nil for drags from Finder.
    /// Items from another phone are left out: they can't move here.
    @MainActor static func paths(in info: any NSDraggingInfo, deviceID: String?) -> [String]? {
        let payloads = (info.draggingPasteboard.pasteboardItems ?? []).compactMap {
            $0.propertyList(forType: .remoteItem) as? [String: String]
        }
        guard !payloads.isEmpty else {
            return nil
        }
        return payloads.filter { $0[Key.device] == deviceID }.compactMap { $0[Key.path] }
    }

    /// Holding Option narrows the drag to copy, as in Finder.
    @MainActor static func mode(for info: any NSDraggingInfo) -> PlaceMode {
        info.draggingSourceOperationMask == .copy ? .copy : .move
    }

    /// A folder that isn't one of the dragged items.
    @MainActor static func canMove(_ paths: [String], onto target: RemoteItem?) -> Bool {
        guard let target, target.isDirectory, !paths.isEmpty else {
            return false
        }
        return !paths.contains(target.path)
    }
}

extension PlaceMode {
    var dragOperation: NSDragOperation {
        switch self {
        case .move: .move
        case .copy: .copy
        }
    }
}
