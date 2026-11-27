import Foundation

/// Where a HEIC file keeps its small preview image.
///
/// Thumbnails read the first 64 KB of a photo and use the preview stored in
/// it. iPhone HEICs often place that preview further in, and a cut-off
/// preview decodes as solid black. The file's index sits at the very start:
///
///     ftyp | meta ─┬─ iref ── thmb   (which item is the preview)
///                  └─ iloc            (byte offset and length of each item)
///          | mdat …                   (the image data itself)
enum HEIFLayout {
    private static let boxHeaderSize = 8
    private static let fullBoxHeaderSize = 4
    private static let largeSizeMarker: UInt32 = 1
    /// `iloc` versions 1 and 2 add a construction method; 0 means "in the file".
    private static let fileConstructionMethod = 0
    private static let longItemIDVersion: UInt8 = 2

    /// How many bytes from the start are needed to decode the preview, or nil
    /// if this isn't a HEIF file with a preview stored in the file body.
    static func previewEnd(in data: Data) -> Int? {
        let reader = Reader(data: data)
        guard let meta = reader.child("meta", in: 0..<data.count) else {
            return nil
        }
        let metaBody = (meta.lowerBound + fullBoxHeaderSize)..<meta.upperBound
        guard let iref = reader.child("iref", in: metaBody),
              let iloc = reader.child("iloc", in: metaBody) else {
            return nil
        }

        let previews = previewItems(reader, iref: iref)
        let ends = previewItemEnds(reader, iloc: iloc, items: previews)
        return ends.max()
    }

    // MARK: iref

    /// Items that are a `thmb` (thumbnail) of another item.
    private static func previewItems(_ reader: Reader, iref: Range<Int>) -> Set<UInt32> {
        guard let version = reader.byte(at: iref.lowerBound) else {
            return []
        }
        let idSize = version == 0 ? 2 : 4
        var items: Set<UInt32> = []
        var position = iref.lowerBound + fullBoxHeaderSize
        while let (kind, range) = reader.box(at: position), range.upperBound <= iref.upperBound {
            if kind == "thmb", let id = reader.unsigned(at: range.lowerBound + boxHeaderSize, size: idSize) {
                items.insert(UInt32(id))
            }
            position = range.upperBound
        }
        return items
    }

    // MARK: iloc

    /// End offset (base + extent offset + length) of each wanted item's data.
    private static func previewItemEnds(_ reader: Reader, iloc: Range<Int>, items: Set<UInt32>) -> [Int] {
        var cursor = iloc.lowerBound
        guard !items.isEmpty, let version = reader.byte(at: cursor),
              let sizes = reader.byte(at: cursor + 4), let more = reader.byte(at: cursor + 5) else {
            return []
        }
        let offsetSize = Int(sizes >> 4)
        let lengthSize = Int(sizes & 0x0F)
        let baseOffsetSize = Int(more >> 4)
        let indexSize = version >= 1 ? Int(more & 0x0F) : 0
        let countSize = version < longItemIDVersion ? 2 : 4
        cursor += fullBoxHeaderSize + 2

        guard let itemCount = reader.unsigned(at: cursor, size: countSize) else {
            return []
        }
        cursor += countSize

        var ends: [Int] = []
        for _ in 0..<itemCount {
            guard let id = reader.unsigned(at: cursor, size: countSize) else {
                return ends
            }
            cursor += countSize
            var constructionMethod = fileConstructionMethod
            if version >= 1 {
                constructionMethod = Int((reader.unsigned(at: cursor, size: 2) ?? 0) & 0x0F)
                cursor += 2
            }
            cursor += 2   // data_reference_index
            let baseOffset = reader.unsigned(at: cursor, size: baseOffsetSize) ?? 0
            cursor += baseOffsetSize
            guard let extentCount = reader.unsigned(at: cursor, size: 2) else {
                return ends
            }
            cursor += 2

            for _ in 0..<extentCount {
                cursor += indexSize
                let offset = reader.unsigned(at: cursor, size: offsetSize) ?? 0
                cursor += offsetSize
                let length = reader.unsigned(at: cursor, size: lengthSize) ?? 0
                cursor += lengthSize
                // Length 0 means "to the end of the file": no useful bound.
                if items.contains(UInt32(id)), constructionMethod == fileConstructionMethod, length > 0 {
                    ends.append(Int(baseOffset + offset + length))
                }
            }
        }
        return ends
    }

    // MARK: Byte reading

    /// Big-endian reads that return nil instead of running past the data.
    private struct Reader {
        let data: Data

        func byte(at offset: Int) -> UInt8? {
            offset >= 0 && offset < data.count ? data[data.startIndex + offset] : nil
        }

        func unsigned(at offset: Int, size: Int) -> UInt64? {
            guard size > 0 else {
                return 0
            }
            guard offset >= 0, offset + size <= data.count else {
                return nil
            }
            return (0..<size).reduce(UInt64(0)) { $0 << 8 | UInt64(data[data.startIndex + offset + $1]) }
        }

        /// A box at `offset`: its four-letter type and its full byte range.
        func box(at offset: Int) -> (String, Range<Int>)? {
            guard let size32 = unsigned(at: offset, size: 4), offset + HEIFLayout.boxHeaderSize <= data.count else {
                return nil
            }
            let kind = String(decoding: data[(data.startIndex + offset + 4)..<(data.startIndex + offset + 8)], as: UTF8.self)
            var size = Int(size32)
            if size32 == UInt64(HEIFLayout.largeSizeMarker), let large = unsigned(at: offset + 8, size: 8) {
                size = Int(large)
            }
            guard size >= HEIFLayout.boxHeaderSize else {
                return nil
            }
            return (kind, offset..<(offset + size))
        }

        /// The body range of the first child box of `kind` within `range`.
        func child(_ kind: String, in range: Range<Int>) -> Range<Int>? {
            var position = range.lowerBound
            while let (found, box) = box(at: position), box.lowerBound < range.upperBound {
                if found == kind {
                    return (box.lowerBound + HEIFLayout.boxHeaderSize)..<min(box.upperBound, data.count)
                }
                position = box.upperBound
            }
            return nil
        }
    }
}
