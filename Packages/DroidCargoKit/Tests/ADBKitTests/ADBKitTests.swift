@testable import ADBKit
import DeviceKit
import Foundation
import Synchronization
import Testing

/// Replays scripted server bytes and records what the client wrote.
final class ScriptedStream: ADBStream, @unchecked Sendable {
    private var incoming: Data
    private(set) var written = Data()

    init(_ incoming: Data) {
        self.incoming = incoming
    }

    func write(_ data: Data) async throws {
        written.append(data)
    }

    func read(exactly count: Int) async throws -> Data {
        guard incoming.count >= count else {
            throw DeviceError.deviceDisconnected
        }
        let chunk = incoming.prefix(count)
        incoming.removeFirst(count)
        return Data(chunk)
    }

    func readToEnd() async throws -> Data {
        defer { incoming.removeAll() }
        return incoming
    }

    func close() {}
}

private extension Data {
    mutating func appendLE64(_ value: UInt64) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    static func ascii(_ text: String) -> Data { Data(text.utf8) }
}

/// Builds one LIS2 "DNT2" entry.
private func dentV2(name: String, mode: UInt32, size: UInt64, mtime: UInt64, error: UInt32 = 0) -> Data {
    var data = Data.ascii("DNT2")
    data.appendLE(error)
    data.appendLE64(0) // dev
    data.appendLE64(0) // ino
    data.appendLE(mode)
    data.appendLE(1) // nlink
    data.appendLE(0) // uid
    data.appendLE(0) // gid
    data.appendLE64(size)
    data.appendLE64(0) // atime
    data.appendLE64(mtime)
    data.appendLE64(0) // ctime
    data.appendLE(UInt32(name.utf8.count))
    data.append(Data(name.utf8))
    return data
}

private func doneV2() -> Data {
    Data.ascii("DONE") + Data(count: 72)
}

struct WireTests {
    @Test func hostRequestPrefixesHexLength() {
        #expect(ADBWire.hostRequest("host:version") == Data.ascii("000chost:version"))
    }

    @Test func shellQuoteEscapesSingleQuotes() {
        #expect(ADBWire.shellQuote("it's") == "'it'\\''s'")
    }

    @Test func failStatusMapsToDeviceError() async {
        let stream = ScriptedStream(Data.ascii("FAIL0010device not found"))
        await #expect(throws: DeviceError.deviceDisconnected) {
            try await ADBWire.readStatus(stream)
        }
    }

    @Test func parsesTrackedDevices() {
        let text = "R58N1234\tdevice product:o1s model:SM_G991B device:o1s transport_id:3\nABC\tunauthorized usb:1-1 transport_id:4\n"
        let devices = ADBDeviceInfo.parse(text)
        #expect(devices.count == 2)
        #expect(devices[0].model == "SM G991B")
        #expect(devices[0].deviceState == .online)
        #expect(devices[1].deviceState == .unauthorized)
        #expect(devices[1].model == "ABC")
    }

    @Test func parsesDiskFree() {
        let output = """
        Filesystem     1K-blocks     Used Available Use% Mounted on
        /dev/fuse      100 40 60  40% /storage/emulated
        """
        let result = ADBDeviceSession.parseDF(output)
        #expect(result.count == 1)
        #expect(result[0].0 == 102_400)
        #expect(result[0].1 == 61_440)
    }
}

struct SyncTests {
    @Test func listsV2EntriesSkippingDotsAndErrors() async throws {
        let reply = dentV2(name: ".", mode: 0o040755, size: 0, mtime: 0)
            + dentV2(name: "DCIM", mode: 0o040755, size: 4096, mtime: 1_700_000_000)
            + dentV2(name: "big.mkv", mode: 0o100644, size: 6_000_000_000, mtime: 1_700_000_001)
            + dentV2(name: "broken", mode: 0, size: 0, mtime: 0, error: 13)
            + doneV2()
        let stream = ScriptedStream(reply)
        let entries = try await SyncClient(stream: stream, useV2: true).list("/sdcard")

        #expect(entries.map(\.name) == ["DCIM", "big.mkv"])
        #expect(entries[0].isDirectory)
        #expect(entries[1].size == 6_000_000_000)
        #expect(stream.written == ADBWire.syncRequest("LIS2", path: "/sdcard"))
    }

    @Test func receiveWritesChunksAndReportsProgress() async throws {
        var reply = Data.ascii("DATA")
        reply.appendLE(3)
        reply.append(Data.ascii("abc"))
        reply.append(Data.ascii("DATA"))
        reply.appendLE(2)
        reply.append(Data.ascii("de"))
        reply.append(Data.ascii("DONE"))
        reply.appendLE(0)

        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        let total = Mutex<UInt64>(0)

        try await SyncClient(stream: ScriptedStream(reply), useV2: true)
            .receive("/x", into: handle, control: TransferControl()) { bytes in total.withLock { $0 += bytes } }
        try handle.close()

        #expect(try Data(contentsOf: url) == Data.ascii("abcde"))
        #expect(total.withLock { $0 } == 5)
    }

    @Test func receiveFailThrowsNotFound() async throws {
        var reply = Data.ascii("FAIL")
        reply.appendLE(25)
        reply.append(Data.ascii("No such file or directory"))
        let handle = FileHandle.nullDevice

        await #expect(throws: DeviceError.notFound("No such file or directory")) {
            try await SyncClient(stream: ScriptedStream(reply), useV2: true)
                .receive("/x", into: handle, control: TransferControl()) { _ in }
        }
    }

    @Test func sendFramesDataAndDone() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data.ascii("hello").write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        var reply = Data.ascii("OKAY")
        reply.appendLE(0)
        let stream = ScriptedStream(reply)

        try await SyncClient(stream: stream, useV2: true).send(
            from: handle, to: "/sdcard/a.txt", mode: 0o100644,
            modified: Date(timeIntervalSince1970: 10), control: TransferControl()
        ) { _ in }

        var expected = ADBWire.syncRequest("SEND", path: "/sdcard/a.txt,33188")
        expected.append(ADBWire.syncRequest("DATA", Data.ascii("hello")))
        expected.append(Data.ascii("DONE"))
        expected.appendLE(10)
        #expect(stream.written == expected)
    }

    @Test func statV2MissingReturnsNil() async throws {
        var reply = Data.ascii("STA2")
        reply.appendLE(2) // ENOENT
        reply.append(Data(count: 64))
        let entry = try await SyncClient(stream: ScriptedStream(reply), useV2: true).stat("/nope")
        #expect(entry == nil)
    }
}
