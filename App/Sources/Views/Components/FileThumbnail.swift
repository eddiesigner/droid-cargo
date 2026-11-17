import CargoServices
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// Real preview for photos and videos, file-type icon for everything else.
struct FileThumbnail: View {
    let item: RemoteItem
    let browser: BrowserModel
    let size: CGFloat
    let pixels: Int

    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .clipShape(.rect(cornerRadius: size > 40 ? 6 : 3))
                    .overlay(alignment: .bottomLeading) { videoBadge }
            } else {
                Image(nsImage: FileIcons.icon(for: item))
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .task(id: "\(item.id)|\(pixels)") {
            guard let deviceID = browser.deviceID, ThumbnailService.canPreview(item) else {
                image = nil
                return
            }
            image = await browser.app.thumbnails.thumbnail(for: item, deviceID: deviceID, maxPixelSize: pixels)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var videoBadge: some View {
        if FileCategory(item) == .video, size > 40 {
            Image(systemName: "play.fill")
                .font(.system(size: max(9, size * 0.09)))
                .foregroundStyle(.white)
                .padding(4)
                .background(.black.opacity(0.45), in: .circle)
                .padding(5)
        }
    }
}

/// System icons matching what Finder shows for each file type.
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for item: RemoteItem) -> NSImage {
        let key = item.isDirectory ? "/folder" : item.fileExtension
        if let cached = cache[key] {
            return cached
        }
        let type: UTType = item.isDirectory ? .folder : (UTType(filenameExtension: item.fileExtension) ?? .data)
        let icon = NSWorkspace.shared.icon(for: type)
        cache[key] = icon
        return icon
    }
}

/// Dragging a phone item to Finder copies it through the transfer queue.
struct DraggedRemoteItem: Transferable {
    let item: RemoteItem
    let browser: BrowserModel

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .item) { dragged in
            let url = try await dragged.export()
            return SentTransferredFile(url, allowAccessingOriginalFile: true)
        }
        .suggestedFileName { $0.item.name }
    }

    @MainActor
    private func export() async throws -> URL {
        guard let device = browser.device else {
            throw DeviceError.deviceDisconnected
        }
        return try await browser.app.exportForDrag(item, from: device)
    }
}
