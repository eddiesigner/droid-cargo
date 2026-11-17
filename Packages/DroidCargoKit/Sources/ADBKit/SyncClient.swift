import DeviceKit
import Foundation

/// File type bits from POSIX `st_mode`.
enum FileMode {
    static let typeMask: UInt32 = 0o170000
    static let directory: UInt32 = 0o040000
    static let symlink: UInt32 = 0o120000
    static let defaultFile: UInt32 = 0o100644
}

/// Directory entry as reported by the device, before symlinks are resolved.
struct SyncEntry: Equatable {
    let name: String
    let mode: UInt32
    let size: UInt64
    let modified: Date

    var isDirectory: Bool { mode & FileMode.typeMask == FileMode.directory }
    var isSymlink: Bool { mode & FileMode.typeMask == FileMode.symlink }
}

/// Speaks the adb "sync:" file protocol over a stream that already switched to it.
///
/// Uses the v2 commands (64-bit sizes) when the device advertises them;
/// v1 truncates files larger than 4 GB.
final class SyncClient: @unchecked Sendable {
    private enum Packet {
        static let list = "LIST"
        static let listV2 = "LIS2"
        static let dent = "DENT"
        static let dentV2 = "DNT2"
        static let stat = "STAT"
        static let statV2 = "STA2"
        static let recv = "RECV"
        static let send = "SEND"
        static let data = "DATA"
        static let done = "DONE"
        static let okay = "OKAY"
        static let fail = "FAIL"
        static let quit = "QUIT"
    }

    /// Byte sizes of fixed reply headers, including the 4-byte id.
    private enum Size {
        static let dentV1 = 20
        static let dentV2 = 76
        static let statV1 = 16
        static let statV2 = 72
        static let header = 8
    }

    /// Largest DATA payload the protocol allows.
    static let maxChunk = 64 * 1024
    /// Several DATA packets are batched into one socket write to cut syscalls.
    private static let packetsPerWrite = 8
    private static let errnoNotFound: UInt32 = 2

    private let stream: ADBStream
    private let useV2: Bool

    init(stream: ADBStream, useV2: Bool) {
        self.stream = stream
        self.useV2 = useV2
    }

    func close() {
        Task { [stream] in
            try? await stream.write(ADBWire.syncRequest(Packet.quit, Data()))
            stream.close()
        }
    }

    // MARK: Listing

    func list(_ path: String) async throws -> [SyncEntry] {
        try await stream.write(ADBWire.syncRequest(useV2 ? Packet.listV2 : Packet.list, path: path))

        var entries: [SyncEntry] = []
        while true {
            let header = try await stream.read(exactly: useV2 ? Size.dentV2 : Size.dentV1)
            let id = String(decoding: header.prefix(4), as: UTF8.self)
            if id == Packet.done {
                return entries
            }
            if id == Packet.fail {
                throw ADBWire.mapFailure(path)
            }
            guard id == (useV2 ? Packet.dentV2 : Packet.dent) else {
                throw DeviceError.protocolViolation("list reply \(id)")
            }

            let entry = try await readEntry(header)
            guard let entry, entry.name != ".", entry.name != ".." else {
                continue
            }
            entries.append(entry)
        }
    }

    private func readEntry(_ header: Data) async throws -> SyncEntry? {
        var reader = LEReader(header)
        reader.skip(4)

        // v1: mode, size, mtime, namelen
        guard useV2 else {
            let mode = reader.u32()
            let size = UInt64(reader.u32())
            let mtime = reader.u32()
            let nameLength = Int(reader.u32())
            let name = String(decoding: try await stream.read(exactly: nameLength), as: UTF8.self)
            return SyncEntry(name: name, mode: mode, size: size, modified: Date(timeIntervalSince1970: TimeInterval(mtime)))
        }

        // v2: error, dev, ino, mode, nlink, uid, gid, size, atime, mtime, ctime, namelen
        let error = reader.u32()
        reader.skip(16)
        let mode = reader.u32()
        reader.skip(12)
        let size = reader.u64()
        reader.skip(8)
        let mtime = reader.u64()
        reader.skip(8)
        let nameLength = Int(reader.u32())
        let name = String(decoding: try await stream.read(exactly: nameLength), as: UTF8.self)
        if error != 0 {
            return nil
        }
        return SyncEntry(name: name, mode: mode, size: size, modified: Date(timeIntervalSince1970: TimeInterval(Int64(bitPattern: mtime))))
    }

    /// Follows symlinks. Returns nil when the path does not exist.
    func stat(_ path: String) async throws -> SyncEntry? {
        try await stream.write(ADBWire.syncRequest(useV2 ? Packet.statV2 : Packet.stat, path: path))
        let reply = try await stream.read(exactly: useV2 ? Size.statV2 : Size.statV1)
        var reader = LEReader(reply)
        let id = String(decoding: reply.prefix(4), as: UTF8.self)
        reader.skip(4)
        let name = RemotePath.name(path)

        guard useV2 else {
            guard id == Packet.stat else {
                throw DeviceError.protocolViolation("stat reply \(id)")
            }
            let mode = reader.u32()
            let size = UInt64(reader.u32())
            let mtime = reader.u32()
            if mode == 0 {
                return nil
            }
            return SyncEntry(name: name, mode: mode, size: size, modified: Date(timeIntervalSince1970: TimeInterval(mtime)))
        }

        guard id == Packet.statV2 else {
            throw DeviceError.protocolViolation("stat reply \(id)")
        }
        let error = reader.u32()
        reader.skip(16)
        let mode = reader.u32()
        reader.skip(12)
        let size = reader.u64()
        reader.skip(8)
        let mtime = reader.u64()
        if error == Self.errnoNotFound {
            return nil
        }
        if error != 0 {
            throw DeviceError.permissionDenied(path)
        }
        return SyncEntry(name: name, mode: mode, size: size, modified: Date(timeIntervalSince1970: TimeInterval(Int64(bitPattern: mtime))))
    }

    // MARK: Transfers

    func receive(_ path: String, into handle: FileHandle, control: TransferControl, progress: ByteProgress) async throws {
        try await stream.write(ADBWire.syncRequest(Packet.recv, path: path))

        while true {
            try await control.checkpoint()
            var header = LEReader(try await stream.read(exactly: Size.header))
            let id = try await readID(from: &header)
            let length = Int(header.u32())

            switch id {
            case Packet.data:
                let chunk = try await stream.read(exactly: length)
                try handle.write(contentsOf: chunk)
                progress(UInt64(length))
            case Packet.done:
                return
            case Packet.fail:
                let message = String(decoding: try await stream.read(exactly: length), as: UTF8.self)
                throw ADBWire.mapFailure(message)
            default:
                throw DeviceError.protocolViolation("recv reply \(id)")
            }
        }
    }

    func send(from handle: FileHandle, to path: String, mode: UInt32, modified: Date, control: TransferControl, progress: ByteProgress) async throws {
        try await stream.write(ADBWire.syncRequest(Packet.send, path: "\(path),\(mode)"))

        // Stream the file as batches of DATA packets.
        let batchSize = Self.maxChunk * Self.packetsPerWrite
        while true {
            try await control.checkpoint()
            guard let block = try handle.read(upToCount: batchSize), !block.isEmpty else {
                break
            }
            var packets = Data(capacity: block.count + Self.packetsPerWrite * Size.header)
            var start = block.startIndex
            while start < block.endIndex {
                let end = min(start + Self.maxChunk, block.endIndex)
                packets.append(ADBWire.syncRequest(Packet.data, block[start..<end]))
                start = end
            }
            try await stream.write(packets)
            progress(UInt64(block.count))
        }

        // DONE carries the modification time; the server answers OKAY or FAIL.
        var done = Data(Packet.done.utf8)
        done.appendLE(UInt32(clamping: Int(modified.timeIntervalSince1970)))
        try await stream.write(done)

        var reply = LEReader(try await stream.read(exactly: Size.header))
        let id = try await readID(from: &reply)
        let length = Int(reply.u32())
        if id == Packet.okay {
            return
        }
        let message = String(decoding: try await stream.read(exactly: length), as: UTF8.self)
        throw ADBWire.mapFailure(message)
    }

    private func readID(from reader: inout LEReader) async throws -> String {
        let raw = reader.u32()
        return withUnsafeBytes(of: raw.littleEndian) { String(decoding: $0, as: UTF8.self) }
    }
}
