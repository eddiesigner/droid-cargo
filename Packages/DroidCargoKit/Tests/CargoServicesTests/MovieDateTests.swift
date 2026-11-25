@testable import CargoServices
import Foundation
import Testing

/// Android files a video under the creation time in its movie header, not the
/// file date. Apple Photos rewrites that header to the export time, so videos
/// dragged from Photos landed on "today" in Gallery.
struct MovieDateTests {
    /// 2025-08-11 09:07:06 UTC, the recording date of the reported video.
    private static let recorded = Date(timeIntervalSince1970: 1_754_903_226)
    /// 2026-11-25 02:31:13 UTC, when Photos exported it.
    private static let exported = Date(timeIntervalSince1970: 1_795_573_873)
    private static let remote = "/sdcard/Pictures/clip.mov"

    @Test func uploadSetsMovieHeaderToOriginalDate() async throws {
        let (session, local) = try Self.setUp()

        try await Self.upload(local, session: session, dates: .keepOriginal)

        let uploaded = try #require(session.data(Self.remote))
        #expect(MovieHeader.creationDates(in: uploaded) == Array(repeating: Self.recorded, count: 3))
    }

    @Test func uploadLeavesMacFileUntouched() async throws {
        let (session, local) = try Self.setUp()
        let before = try Data(contentsOf: local)

        try await Self.upload(local, session: session, dates: .keepOriginal)

        #expect(try Data(contentsOf: local) == before)
    }

    @Test func transferDateLeavesMovieHeaderAlone() async throws {
        let (session, local) = try Self.setUp()

        try await Self.upload(local, session: session, dates: .useTransferDate)

        let uploaded = try #require(session.data(Self.remote))
        #expect(MovieHeader.creationDates(in: uploaded) == Array(repeating: Self.exported, count: 3))
    }

    // MARK: Helpers

    /// A minimal movie stamped with the export time, created on the recording date.
    private static func setUp() throws -> (FakeSession, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "droidcargo-movie-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "clip.mov")
        try movie(stamped: exported).write(to: url)
        try FileManager.default.setAttributes([.creationDate: recorded, .modificationDate: Date()], ofItemAtPath: url.path)
        return (FakeSession(), url)
    }

    ///     ftyp | moov ─┬─ mvhd
    ///                  └─ trak ─┬─ tkhd
    ///                           └─ mdia ── mdhd
    ///     | mdat
    static func movie(stamped date: Date) -> Data {
        let seconds = UInt32(date.timeIntervalSince1970 + MovieHeader.epochOffset)
        func atom(_ kind: String, _ body: Data) -> Data {
            var data = Data()
            data.append(contentsOf: withUnsafeBytes(of: UInt32(body.count + 8).bigEndian, Array.init))
            data.append(Data(kind.utf8))
            data.append(body)
            return data
        }
        func stamped(_ kind: String, padding: Int) -> Data {
            var body = Data([0, 0, 0, 0]) // version 0, flags
            body.append(contentsOf: withUnsafeBytes(of: seconds.bigEndian, Array.init))
            body.append(contentsOf: withUnsafeBytes(of: seconds.bigEndian, Array.init))
            body.append(Data(count: padding))
            return atom(kind, body)
        }
        let trak = atom("trak", stamped("tkhd", padding: 72) + atom("mdia", stamped("mdhd", padding: 12)))
        return atom("ftyp", Data("qt  ".utf8)) + atom("moov", stamped("mvhd", padding: 88) + trak) + atom("mdat", Data(count: 64))
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

    private static func upload(_ url: URL, session: FakeSession, dates: FileDatePolicy) async throws {
        let plan = try await TransferEngine.planUpload([url], to: "/sdcard/Pictures", session: session) { _, _ in }
        try await engine(session, dates: dates).run(plan)
    }
}
