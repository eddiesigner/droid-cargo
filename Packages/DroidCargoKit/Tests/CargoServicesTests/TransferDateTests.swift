@testable import CargoServices
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// Copied files keep the date from the other side unless the user asks for
/// the transfer date.
struct TransferDateTests {
    /// 2021-06-15 12:00 UTC: clearly not "now".
    private static let original = Date(timeIntervalSince1970: 1_623_758_400)
    /// How close to "now" a transfer-date file must be.
    private static let nowTolerance: TimeInterval = 60

    @Test func downloadKeepsOriginalDates() async throws {
        let (session, folder) = try Self.setUp()
        session.put("/sdcard/DCIM/a.jpg", "photo")
        let item = RemoteItem(path: "/sdcard/DCIM/a.jpg", name: "a.jpg", kind: .file, size: 5, modified: Self.original)

        try await Self.download(item, to: folder, session: session, dates: .keepOriginal)

        let attributes = try FileManager.default.attributesOfItem(atPath: folder.appending(path: "a.jpg").path)
        #expect(attributes[.modificationDate] as? Date == Self.original)
        #expect(attributes[.creationDate] as? Date == Self.original)
    }

    @Test func downloadCanUseTransferDate() async throws {
        let (session, folder) = try Self.setUp()
        session.put("/sdcard/DCIM/a.jpg", "photo")
        let item = RemoteItem(path: "/sdcard/DCIM/a.jpg", name: "a.jpg", kind: .file, size: 5, modified: Self.original)

        try await Self.download(item, to: folder, session: session, dates: .useTransferDate)

        let attributes = try FileManager.default.attributesOfItem(atPath: folder.appending(path: "a.jpg").path)
        let modified = try #require(attributes[.modificationDate] as? Date)
        #expect(abs(modified.timeIntervalSinceNow) < Self.nowTolerance)
    }

    @Test func uploadKeepsOriginalDate() async throws {
        let (session, folder) = try Self.setUp()
        let local = try Self.localFile(in: folder)

        try await Self.upload(local, session: session, dates: .keepOriginal)

        #expect(session.modified("/sdcard/Pictures/b.jpg") == Self.original)
    }

    @Test func uploadCanUseTransferDate() async throws {
        let (session, folder) = try Self.setUp()
        let local = try Self.localFile(in: folder)

        try await Self.upload(local, session: session, dates: .useTransferDate)

        let modified = try #require(session.modified("/sdcard/Pictures/b.jpg"))
        #expect(abs(modified.timeIntervalSinceNow) < Self.nowTolerance)
    }

    /// Android only files a photo under its capture date when the file date is
    /// near it (or the photo has a timezone), so uploads send the capture date.
    @Test func uploadUsesPhotoCaptureDate() async throws {
        let (session, folder) = try Self.setUp()
        let photo = try Self.photo(in: folder, captured: "2019:03:10 15:30:00", offset: nil)

        try await Self.upload(photo, session: session, dates: .keepOriginal)

        var components = DateComponents(year: 2019, month: 3, day: 10, hour: 15, minute: 30)
        components.timeZone = .current
        let expected = try #require(Calendar(identifier: .gregorian).date(from: components))
        #expect(session.modified("/sdcard/Pictures/photo.jpg") == expected)
    }

    @Test func uploadUsesCaptureDateTimezone() async throws {
        let (session, folder) = try Self.setUp()
        let photo = try Self.photo(in: folder, captured: "2019:03:10 15:30:00", offset: "-06:00")

        try await Self.upload(photo, session: session, dates: .keepOriginal)

        // 15:30 at UTC−6 is 21:30 UTC.
        #expect(session.modified("/sdcard/Pictures/photo.jpg") == Date(timeIntervalSince1970: 1_552_253_400))
    }

    /// Files dragged out of Apple Photos have today as their modified date
    /// but keep the capture date as their created date.
    @Test func uploadUsesEarlierCreationDate() async throws {
        let (session, folder) = try Self.setUp()
        let local = folder.appending(path: "export.png")
        try "no exif".write(to: local, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.creationDate: Self.original, .modificationDate: Date()], ofItemAtPath: local.path)

        try await Self.upload(local, session: session, dates: .keepOriginal)

        #expect(session.modified("/sdcard/Pictures/export.png") == Self.original)
    }

    // MARK: Helpers

    /// A JPEG with an EXIF capture date, whose file date is the unrelated `original`.
    private static func photo(in folder: URL, captured: String, offset: String?) throws -> URL {
        let url = folder.appending(path: "photo.jpg")
        let context = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        var exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: captured]
        exif[kCGImagePropertyExifOffsetTimeOriginal] = offset
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyExifDictionary: exif] as CFDictionary)
        CGImageDestinationFinalize(destination)
        try FileManager.default.setAttributes([.modificationDate: original], ofItemAtPath: url.path)
        return url
    }

    private static func setUp() throws -> (FakeSession, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "droidcargo-dates-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (FakeSession(), folder)
    }

    private static func localFile(in folder: URL) throws -> URL {
        let url = folder.appending(path: "b.jpg")
        try "photo".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: original], ofItemAtPath: url.path)
        return url
    }

    private static func engine(_ session: FakeSession, dates: FileDatePolicy) -> TransferEngine {
        TransferEngine(
            sessions: SessionSource(get: { _ in session }, invalidate: {}),
            options: TransferOptions(conflictPolicy: .keepBoth, parallelism: 1, scanMediaAfterUpload: false, dates: dates),
            control: TransferControl(),
            counter: ByteCounter(),
            conflicts: ConflictArbiter { _ in (.skip, .thisItem) },
            onFileStarted: { _ in },
            onFileFinished: { _ in }
        )
    }

    private static func download(_ item: RemoteItem, to folder: URL, session: FakeSession, dates: FileDatePolicy) async throws {
        let plan = try await TransferEngine.planDownload([(item, folder)], session: session) { _, _ in }
        try await engine(session, dates: dates).run(plan)
    }

    private static func upload(_ url: URL, session: FakeSession, dates: FileDatePolicy) async throws {
        let plan = try await TransferEngine.planUpload([url], to: "/sdcard/Pictures", session: session) { _, _ in }
        try await engine(session, dates: dates).run(plan)
    }
}
