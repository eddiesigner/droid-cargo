@testable import CargoServices
import Foundation
import Synchronization
import Testing

/// In-memory phone file system.
final class FakeSession: DeviceSession, @unchecked Sendable {
    let device = Device(id: "fake", name: "Fake", model: "Fake", state: .online, transport: .adb)
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var folders: Set<String> = ["/sdcard"]
    /// Number of upcoming downloads that fail with a transient error.
    var failNextDownloads = 0
    /// Whole-file downloads so far; thumbnail tests check prefix-only reads.
    private(set) var downloadCount = 0

    func put(_ path: String, _ text: String) {
        put(path, data: Data(text.utf8))
    }

    func put(_ path: String, data: Data) {
        lock.withLock {
            files[path] = data
            var parent = RemotePath.parent(path)
            while parent != "/" {
                folders.insert(parent)
                parent = RemotePath.parent(parent)
            }
        }
    }

    func contents(_ path: String) -> String? {
        lock.withLock { files[path].map { String(decoding: $0, as: UTF8.self) } }
    }

    func allPaths() -> [String] {
        lock.withLock { files.keys.sorted() }
    }

    func storages() async throws -> [Storage] { [] }

    func list(_ directory: String) async throws -> [RemoteItem] {
        lock.withLock {
            let fileItems = files.filter { RemotePath.parent($0.key) == directory }.map {
                RemoteItem(path: $0.key, name: RemotePath.name($0.key), kind: .file, size: UInt64($0.value.count), modified: Date(timeIntervalSince1970: 0))
            }
            let folderItems = folders.filter { RemotePath.parent($0) == directory && $0 != directory }.map {
                RemoteItem(path: $0, name: RemotePath.name($0), kind: .directory, size: 0, modified: Date(timeIntervalSince1970: 0))
            }
            return fileItems + folderItems
        }
    }

    func stat(_ path: String) async throws -> RemoteItem? {
        lock.withLock {
            if let data = files[path] {
                return RemoteItem(path: path, name: RemotePath.name(path), kind: .file, size: UInt64(data.count), modified: Date())
            }
            if folders.contains(path) {
                return RemoteItem(path: path, name: RemotePath.name(path), kind: .directory, size: 0, modified: Date())
            }
            return nil
        }
    }

    func readPrefix(_ remotePath: String, maxBytes: Int) async throws -> Data {
        lock.withLock { files[remotePath]?.prefix(maxBytes) ?? Data() }
    }

    func readSuffix(_ remotePath: String, maxBytes: Int) async throws -> Data {
        lock.withLock { files[remotePath]?.suffix(maxBytes) ?? Data() }
    }

    func download(_ remotePath: String, to localURL: URL, control: TransferControl, progress: ByteProgress) async throws {
        let shouldFail = lock.withLock {
            defer { failNextDownloads = max(0, failNextDownloads - 1) }
            return failNextDownloads > 0
        }
        if shouldFail {
            throw DeviceError.deviceDisconnected
        }
        lock.withLock { downloadCount += 1 }
        guard let data = lock.withLock({ files[remotePath] }) else {
            throw DeviceError.notFound(remotePath)
        }
        try data.write(to: localURL)
        progress(UInt64(data.count))
    }

    func upload(_ localURL: URL, to remotePath: String, modified: Date, control: TransferControl, progress: ByteProgress) async throws {
        let data = try Data(contentsOf: localURL)
        lock.withLock { files[remotePath] = data }
        progress(UInt64(data.count))
    }

    func makeDirectory(_ path: String) async throws {
        lock.withLock { _ = folders.insert(path) }
    }

    func move(_ source: String, to destination: String) async throws {
        lock.withLock {
            files[destination] = files.removeValue(forKey: source)
        }
    }

    func remove(_ path: String) async throws {
        lock.withLock { _ = files.removeValue(forKey: path) }
    }

    func notifyMediaScanner(_ paths: [String]) async {}
}

private func makeTempFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "droidcargo-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

final class OutcomeLog: Sendable {
    let items = Mutex<[FileOutcome]>([])
}

private func makeEngine(_ session: FakeSession, policy: ConflictPolicy = .keepBoth, outcomes: OutcomeLog = OutcomeLog()) -> TransferEngine {
    TransferEngine(
        sessions: SessionSource(get: { _ in session }, invalidate: {}),
        options: TransferOptions(conflictPolicy: policy, parallelism: 2, scanMediaAfterUpload: false),
        control: TransferControl(),
        counter: ByteCounter(),
        conflicts: ConflictArbiter { _ in (.skip, .thisItem) },
        onFileStarted: { _ in },
        onFileFinished: { outcome in outcomes.items.withLock { $0.append(outcome) } }
    )
}

struct TransferEngineTests {
    @Test func downloadsFolderTreeRecursively() async throws {
        let session = FakeSession()
        session.put("/sdcard/DCIM/a.jpg", "aaa")
        session.put("/sdcard/DCIM/Trip/b.jpg", "bb")
        let folder = try makeTempFolder()
        let root = RemoteItem(path: "/sdcard/DCIM", name: "DCIM", kind: .directory, size: 0, modified: Date())

        let plan = try await TransferEngine.planDownload([(root, folder)], session: session) { _, _ in }
        let outcomes = OutcomeLog()
        try await makeEngine(session, outcomes: outcomes).run(plan)

        #expect(plan.count == 2)
        #expect(try String(contentsOf: folder.appending(path: "DCIM/a.jpg"), encoding: .utf8) == "aaa")
        #expect(try String(contentsOf: folder.appending(path: "DCIM/Trip/b.jpg"), encoding: .utf8) == "bb")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "DCIM").path)
        #expect(!leftovers.contains { $0.hasSuffix(TransferEngine.tempSuffix) })
    }

    @Test func keepBothAddsNumberSuffix() async throws {
        let session = FakeSession()
        session.put("/sdcard/a.txt", "new")
        let folder = try makeTempFolder()
        try "old".write(to: folder.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        let item = RemoteItem(path: "/sdcard/a.txt", name: "a.txt", kind: .file, size: 3, modified: Date())

        let plan = try await TransferEngine.planDownload([(item, folder)], session: session) { _, _ in }
        try await makeEngine(session, policy: .keepBoth).run(plan)

        #expect(try String(contentsOf: folder.appending(path: "a.txt"), encoding: .utf8) == "old")
        #expect(try String(contentsOf: folder.appending(path: "a 2.txt"), encoding: .utf8) == "new")
    }

    @Test func retriesTransientFailures() async throws {
        let session = FakeSession()
        session.put("/sdcard/a.txt", "data")
        session.failNextDownloads = 1
        let folder = try makeTempFolder()
        let item = RemoteItem(path: "/sdcard/a.txt", name: "a.txt", kind: .file, size: 4, modified: Date())
        let outcomes = OutcomeLog()

        try await makeEngine(session, outcomes: outcomes).run([.download(remotePath: item.path, size: 4, modified: Date(), localURL: folder.appending(path: "a.txt"))])

        #expect(try String(contentsOf: folder.appending(path: "a.txt"), encoding: .utf8) == "data")
        let succeeded = outcomes.items.withLock { $0.contains { if case .transferred = $0 { true } else { false } } }
        #expect(succeeded)
    }

    @Test func uploadsFolderAndSkipsDSStore() async throws {
        let session = FakeSession()
        let folder = try makeTempFolder()
        let album = folder.appending(path: "Album")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        try "x".write(to: album.appending(path: "one.jpg"), atomically: true, encoding: .utf8)
        try "junk".write(to: album.appending(path: ".DS_Store"), atomically: true, encoding: .utf8)

        let plan = try await TransferEngine.planUpload([album], to: "/sdcard/Pictures", session: session) { _, _ in }
        try await makeEngine(session).run(plan)

        #expect(session.allPaths() == ["/sdcard/Pictures/Album/one.jpg"])
    }

    @Test func skipPolicyLeavesExistingRemoteFile() async throws {
        let session = FakeSession()
        session.put("/sdcard/a.txt", "old")
        let folder = try makeTempFolder()
        let local = folder.appending(path: "a.txt")
        try "new".write(to: local, atomically: true, encoding: .utf8)

        let plan = try await TransferEngine.planUpload([local], to: "/sdcard", session: session) { _, _ in }
        try await makeEngine(session, policy: .skip).run(plan)

        #expect(session.contents("/sdcard/a.txt") == "old")
    }

    @Test func numberedKeepsExtension() {
        #expect(TransferEngine.numbered("/a/photo.jpg", 2) == "/a/photo 2.jpg")
        #expect(TransferEngine.numbered("/a/README", 3) == "/a/README 3")
    }
}
