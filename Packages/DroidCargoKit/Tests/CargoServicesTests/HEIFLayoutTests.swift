@testable import CargoServices
import Foundation
import Testing

/// HEIC files list where each image's bytes live. iPhone photos often keep
/// the small preview past the first 64 KB, so the app must know how far to read.
struct HEIFLayoutTests {
    private static let primaryID: UInt16 = 1
    private static let previewID: UInt16 = 2

    @Test func findsWhereThePreviewEnds() {
        let file = Self.heif(references: true, extents: [
            (Self.primaryID, offset: 100_000, length: 900_000),
            (Self.previewID, offset: 200_000, length: 30_000),
        ])

        #expect(HEIFLayout.previewEnd(in: file) == 230_000)
    }

    @Test func noPreviewReferenceMeansNoAnswer() {
        let file = Self.heif(references: false, extents: [(Self.primaryID, offset: 100_000, length: 900_000)])

        #expect(HEIFLayout.previewEnd(in: file) == nil)
    }

    @Test func notHEIFMeansNoAnswer() {
        #expect(HEIFLayout.previewEnd(in: Data([0xFF, 0xD8, 0xFF, 0xE1])) == nil)
    }

    // MARK: Builders

    ///     ftyp | meta ─┬─ iref ── thmb (preview → primary)
    ///                  └─ iloc (version 0, 4-byte offsets and lengths)
    private static func heif(references: Bool, extents: [(UInt16, offset: UInt32, length: UInt32)]) -> Data {
        var iloc = Data([0, 0, 0, 0])            // version 0, flags
        iloc.append(0x44)                        // offset_size 4, length_size 4
        iloc.append(0x00)                        // base_offset_size 0, reserved
        iloc.append(u16(UInt16(extents.count)))
        for extent in extents {
            iloc.append(u16(extent.0))           // item_ID
            iloc.append(u16(0))                  // data_reference_index
            iloc.append(u16(1))                  // extent_count
            iloc.append(u32(extent.offset))
            iloc.append(u32(extent.length))
        }

        var meta = Data([0, 0, 0, 0])            // version 0, flags
        if references {
            var thmb = u16(previewID)            // from_item_ID
            thmb.append(u16(1))                  // reference_count
            thmb.append(u16(primaryID))          // to_item_ID
            meta.append(box("iref", Data([0, 0, 0, 0]) + box("thmb", thmb)))
        }
        meta.append(box("iloc", iloc))
        return box("ftyp", Data("heic".utf8) + u32(0)) + box("meta", meta)
    }

    private static func box(_ kind: String, _ body: Data) -> Data {
        u32(UInt32(body.count + 8)) + Data(kind.utf8) + body
    }

    private static func u16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    private static func u32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
}
