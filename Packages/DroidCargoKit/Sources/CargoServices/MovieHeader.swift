import Foundation

/// Creation times in a QuickTime / MP4 header.
///
/// Android files a video under the creation time in its movie header (`mvhd`),
/// not the file date. Apple Photos rewrites that header to the export time, so
/// a video dragged out of Photos lands on "today" in Gallery. Rewriting these
/// fixed-size fields changes no layout and leaves the media data untouched.
///
///     ftyp | moov ─┬─ mvhd               (created, modified)
///                  └─ trak ─┬─ tkhd      (created, modified)
///                           └─ mdia ── mdhd (created, modified)
///     | mdat …
enum MovieHeader {
    static let fileExtensions: Set<String> = ["mov", "mp4", "m4v", "3gp"]
    /// Seconds between 1904-01-01 (QuickTime's epoch) and 1970-01-01.
    static let epochOffset: TimeInterval = 2_082_844_800

    private static let stampedAtoms: Set<String> = ["mvhd", "tkhd", "mdhd"]
    private static let containerAtoms: Set<String> = ["moov", "trak", "mdia"]
    private static let atomHeaderSize = 8
    private static let largeSizeMarker: UInt64 = 1
    private static let toEndMarker: UInt64 = 0
    /// Version and flags precede the dates inside a stamped atom.
    private static let versionFlagsSize: UInt64 = 4
    private static let longDatesVersion: UInt8 = 1

    /// Where one atom's creation date sits, and how wide its date fields are.
    private struct Stamp {
        let offset: UInt64
        let isLong: Bool
    }

    private typealias Reader = (_ offset: UInt64, _ count: Int) throws -> Data

    // MARK: Reading

    static func creationDates(in data: Data) -> [Date] {
        let read: Reader = { offset, count in
            let start = data.startIndex + Int(offset)
            return data[start..<min(start + count, data.endIndex)]
        }
        let stamps = (try? stamps(read: read, length: UInt64(data.count))) ?? []
        return stamps.compactMap { try? date(at: $0, read: read) }
    }

    /// The movie's own creation time (`mvhd`), or nil if the file isn't a movie.
    static func creationDate(of url: URL) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        let read = reader(handle)
        guard let length = try? handle.seekToEnd(),
              let first = try? stamps(read: read, length: length).first else {
            return nil
        }
        return try? date(at: first, read: read)
    }

    // MARK: Writing

    /// Sets every creation and modification time in the header to `date`.
    static func setDates(_ date: Date, in url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        let seconds = date.timeIntervalSince1970 + epochOffset

        for stamp in try stamps(read: reader(handle), length: length) {
            var bytes = Data()
            if stamp.isLong {
                bytes.appendBigEndian(UInt64(seconds))
                bytes.appendBigEndian(UInt64(seconds))
            } else {
                bytes.appendBigEndian(UInt32(clamping: Int64(seconds)))
                bytes.appendBigEndian(UInt32(clamping: Int64(seconds)))
            }
            try handle.seek(toOffset: stamp.offset)
            try handle.write(contentsOf: bytes)
        }
    }

    // MARK: Atom walk

    private static func reader(_ handle: FileHandle) -> Reader {
        { offset, count in
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count) ?? Data()
        }
    }

    private static func stamps(read: Reader, length: UInt64) throws -> [Stamp] {
        var found: [Stamp] = []
        try walk(from: 0, to: length, read: read, into: &found)
        return found
    }

    private static func walk(from start: UInt64, to end: UInt64, read: Reader, into found: inout [Stamp]) throws {
        var position = start
        while position + UInt64(atomHeaderSize) <= end {
            let header = try read(position, atomHeaderSize)
            guard header.count == atomHeaderSize else {
                return
            }
            var size = UInt64(header.bigEndian(UInt32.self, at: 0))
            let kind = String(decoding: header.suffix(4), as: UTF8.self)
            var headerSize = UInt64(atomHeaderSize)
            if size == largeSizeMarker {
                size = try read(position + headerSize, MemoryLayout<UInt64>.size).bigEndian(UInt64.self, at: 0)
                headerSize += UInt64(MemoryLayout<UInt64>.size)
            } else if size == toEndMarker {
                size = end - position
            }
            guard size >= headerSize, position + size <= end else {
                return
            }

            let body = position + headerSize
            if stampedAtoms.contains(kind), let version = try read(body, 1).first {
                found.append(Stamp(offset: body + versionFlagsSize, isLong: version == longDatesVersion))
            }
            if containerAtoms.contains(kind) {
                try walk(from: body, to: position + size, read: read, into: &found)
            }
            position += size
        }
    }

    private static func date(at stamp: Stamp, read: Reader) throws -> Date {
        let width = stamp.isLong ? MemoryLayout<UInt64>.size : MemoryLayout<UInt32>.size
        let bytes = try read(stamp.offset, width)
        let seconds = stamp.isLong ? Double(bytes.bigEndian(UInt64.self, at: 0)) : Double(bytes.bigEndian(UInt32.self, at: 0))
        return Date(timeIntervalSince1970: seconds - epochOffset)
    }
}

private extension Data {
    func bigEndian<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        var value: T = 0
        for byte in self.dropFirst(offset).prefix(MemoryLayout<T>.size) {
            value = value << 8 | T(byte)
        }
        return value
    }

    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
