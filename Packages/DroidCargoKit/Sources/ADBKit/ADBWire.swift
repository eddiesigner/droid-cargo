import DeviceKit
import Foundation

/// Encoding and decoding for the adb host and sync wire formats.
///
/// Host request:   "000c" "host:version"      (4 hex digit length + payload)
/// Host reply:     "OKAY" | "FAIL" "0012" "<message>"
/// Sync packet:    "LIS2" <UInt32 LE length> <path>
enum ADBWire {
    static let okay = "OKAY"
    static let fail = "FAIL"

    static func hostRequest(_ payload: String) -> Data {
        let body = Data(payload.utf8)
        return Data(String(format: "%04x", body.count).utf8) + body
    }

    static func syncRequest(_ id: String, _ payload: Data) -> Data {
        var data = Data(id.utf8)
        data.appendLE(UInt32(payload.count))
        data.append(payload)
        return data
    }

    static func syncRequest(_ id: String, path: String) -> Data {
        syncRequest(id, Data(path.utf8))
    }

    static func hexLength(_ data: Data) throws -> Int {
        guard let text = String(data: data, encoding: .ascii), let value = Int(text, radix: 16) else {
            throw DeviceError.protocolViolation("bad length prefix")
        }
        return value
    }

    /// Reads "OKAY", or throws the server's FAIL message.
    static func readStatus(_ stream: ADBStream) async throws {
        let status = try await stream.read(exactly: 4)
        if status == Data(okay.utf8) {
            return
        }
        guard status == Data(fail.utf8) else {
            throw DeviceError.protocolViolation(String(decoding: status, as: UTF8.self))
        }
        let message = try await readHexString(stream)
        throw ADBWire.mapFailure(message)
    }

    static func readHexString(_ stream: ADBStream) async throws -> String {
        let length = try hexLength(try await stream.read(exactly: 4))
        let body = try await stream.read(exactly: length)
        return String(decoding: body, as: UTF8.self)
    }

    static func mapFailure(_ message: String) -> DeviceError {
        let lower = message.lowercased()
        if lower.contains("not found") && lower.contains("device") {
            return .deviceDisconnected
        }
        if lower.contains("no such file") {
            return .notFound(message)
        }
        if lower.contains("permission denied") || lower.contains("read-only") {
            return .permissionDenied(message)
        }
        return .remote(message)
    }

    /// Quotes a string for /system/bin/sh on the device.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Little-endian cursor over a sync reply.
struct LEReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    mutating func u32() -> UInt32 {
        defer { offset += 4 }
        return data[offset..<offset + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func u64() -> UInt64 {
        defer { offset += 8 }
        return data[offset..<offset + 8].reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }

    mutating func skip(_ count: Int) {
        offset += count
    }
}

extension Data {
    mutating func appendLE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
