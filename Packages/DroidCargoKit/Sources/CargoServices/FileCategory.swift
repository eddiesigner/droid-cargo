import DeviceKit
import Foundation
import UniformTypeIdentifiers

public enum FileCategory: Sendable {
    case folder
    case image
    case video
    case audio
    case document
    case archive
    case androidPackage
    case other

    private static let images: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp", "tif", "tiff", "dng", "avif"]
    private static let videos: Set<String> = ["mp4", "mov", "m4v", "3gp", "mkv", "webm", "avi"]
    private static let audioFiles: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "amr"]
    private static let documents: Set<String> = ["pdf", "txt", "md", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "csv", "rtf", "pages", "numbers", "key", "epub"]
    private static let archives: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"]

    public init(_ item: RemoteItem) {
        if item.isDirectory {
            self = .folder
            return
        }
        self.init(fileExtension: item.fileExtension)
    }

    public init(fileExtension ext: String) {
        switch ext {
        case _ where Self.images.contains(ext): self = .image
        case _ where Self.videos.contains(ext): self = .video
        case _ where Self.audioFiles.contains(ext): self = .audio
        case _ where Self.documents.contains(ext): self = .document
        case _ where Self.archives.contains(ext): self = .archive
        case "apk", "apks", "xapk": self = .androidPackage
        default: self = .other
        }
    }

    public var isMedia: Bool { self == .image || self == .video }

    /// Human-readable kind for the list's "Kind" column, e.g. "JPEG image".
    public static func kindDescription(for item: RemoteItem) -> String {
        if item.isDirectory {
            return String(localized: "Folder")
        }
        if let type = UTType(filenameExtension: item.fileExtension), let description = type.localizedDescription {
            return description
        }
        return item.fileExtension.isEmpty ? String(localized: "Document") : item.fileExtension.uppercased()
    }
}
