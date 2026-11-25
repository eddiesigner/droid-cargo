@testable import ADBKit
@testable import CargoServices
import Foundation
import Testing

/// Checks dates survive real transfers. Enable with `DROIDCARGO_DEVICE_TESTS=1`.
/// Uploads one small file to the phone's Download folder and deletes it afterwards.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DROIDCARGO_DEVICE_TESTS"] == "1"))
struct TransferDateDeviceTests {
    private static let original = Date(timeIntervalSince1970: 1_623_758_400)
    private static let remoteFolder = "/storage/emulated/0/Download"
    private static let cameraFolder = "/storage/emulated/0/DCIM/Camera"

    @Test func uploadKeepsOriginalDateOnPhone() async throws {
        let session = try await Self.openSession()
        let local = FileManager.default.temporaryDirectory.appending(path: "droidcargo-date-\(UUID().uuidString).txt")
        try "date test".write(to: local, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Self.original], ofItemAtPath: local.path)
        let remote = RemotePath.join(Self.remoteFolder, local.lastPathComponent)
        defer {
            try? FileManager.default.removeItem(at: local)
            Task { try? await session.remove(remote) }
        }

        let plan = try await TransferEngine.planUpload([local], to: Self.remoteFolder, session: session) { _, _ in }
        try await Self.engine(session).run(plan)

        let uploaded = try #require(try await session.stat(remote))
        print("DEVICE upload date: sent \(Self.original), phone has \(uploaded.modified)")
        try await session.remove(remote)
        #expect(uploaded.modified == Self.original)
    }

    /// What Gallery and Google Photos read: MediaStore's dates, not the file's.
    @Test func uploadedImageHasOriginalDateInMediaStore() async throws {
        let source = try #require(ProcessInfo.processInfo.environment["DROIDCARGO_DATE_TEST_JPEG"])
        let session = try await Self.openSession()
        let local = FileManager.default.temporaryDirectory.appending(path: "droidcargo-date-\(UUID().uuidString).jpg")
        try FileManager.default.copyItem(at: URL(filePath: source), to: local)
        try FileManager.default.setAttributes([.modificationDate: Self.original], ofItemAtPath: local.path)
        let folder = "/storage/emulated/0/Pictures/DroidCargoDateTest"
        let remote = RemotePath.join(folder, local.lastPathComponent)
        defer { try? FileManager.default.removeItem(at: local) }

        let plan = try await TransferEngine.planUpload([local], to: folder, session: session) { _, _ in }
        try await Self.engine(session).run(plan)
        await session.notifyMediaScanner([remote])
        try await Task.sleep(for: .seconds(3))

        let client = ADBClient(launcher: ADBServerLauncher())
        let serial = try #require(ProcessInfo.processInfo.environment["DROIDCARGO_SERIAL"])
        let row = try await client.shell(
            "content query --uri content://media/external/images/media --projection _data:date_modified:datetaken:date_added --where \"_data='\(remote)'\"",
            serial: serial
        )
        print("DEVICE mediastore (original \(Int(Self.original.timeIntervalSince1970))): \(row.trimmingCharacters(in: .whitespacesAndNewlines))")
        try await session.remove(folder)
        #expect(!row.contains("datetaken=NULL"))
    }

    /// adb writes files as `com.android.shell`; Google Photos then shows "Shell"
    /// as their source and can't move them to the trash.
    @Test func uploadedFileHasNoShellOwner() async throws {
        let session = try await Self.openSession()
        let local = FileManager.default.temporaryDirectory.appending(path: "droidcargo-owner-\(UUID().uuidString).jpg")
        let source = try #require(ProcessInfo.processInfo.environment["DROIDCARGO_DATE_TEST_JPEG"])
        try FileManager.default.copyItem(at: URL(filePath: source), to: local)
        let folder = "/storage/emulated/0/Pictures/DroidCargoOwnerTest"
        let remote = RemotePath.join(folder, local.lastPathComponent)
        defer { try? FileManager.default.removeItem(at: local) }

        let plan = try await TransferEngine.planUpload([local], to: folder, session: session) { _, _ in }
        try await Self.engine(session).run(plan)
        // Same order as TransferService: index, then clear the owner. No waiting.
        await session.notifyMediaScanner([remote])
        await session.releaseOwnership([remote])

        let client = ADBClient(launcher: ADBServerLauncher())
        let serial = try #require(ProcessInfo.processInfo.environment["DROIDCARGO_SERIAL"])
        let row = try await client.shell(
            "content query --uri content://media/external/file --projection owner_package_name --where \"_data='\(remote)'\"",
            serial: serial
        )
        print("DEVICE owner: \(row.trimmingCharacters(in: .whitespacesAndNewlines))")
        try await session.remove(folder)
        #expect(row.contains("owner_package_name=NULL"))
    }

    /// Uploads a user-supplied file (DROIDCARGO_UPLOAD_FILE) the way the app does
    /// and prints what Android recorded. Leaves it on the phone for manual checks
    /// in DROIDCARGO_UPLOAD_FOLDER.
    @Test func uploadUserFileLikeTheApp() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["DROIDCARGO_UPLOAD_FILE"])
        let folder = try #require(ProcessInfo.processInfo.environment["DROIDCARGO_UPLOAD_FOLDER"])
        let session = try await Self.openSession()
        let local = URL(filePath: path)
        let remote = RemotePath.join(folder, local.lastPathComponent)

        let plan = try await TransferEngine.planUpload([local], to: folder, session: session) { _, _ in }
        if case .upload(_, _, let modified, _) = plan.first {
            print("DEVICE planned upload date: \(modified)")
        }
        try await Self.engine(session).run(plan)
        await session.notifyMediaScanner([remote])
        await session.releaseOwnership([remote])

        let client = ADBClient(launcher: ADBServerLauncher())
        let serial = try #require(ProcessInfo.processInfo.environment["DROIDCARGO_SERIAL"])
        let row = try await client.shell(
            "content query --uri content://media/external/file --projection _id:mime_type:owner_package_name:date_modified:datetaken:date_added --where \"_data='\(remote)'\"",
            serial: serial
        )
        print("DEVICE row: \(row.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    @Test func downloadKeepsOriginalDateOnMac() async throws {
        let session = try await Self.openSession()
        let item = try #require(try await session.list(Self.cameraFolder).first { !$0.isDirectory })
        let folder = FileManager.default.temporaryDirectory.appending(path: "droidcargo-date-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let plan = try await TransferEngine.planDownload([(item, folder)], session: session) { _, _ in }
        try await Self.engine(session).run(plan)

        let attributes = try FileManager.default.attributesOfItem(atPath: folder.appending(path: item.name).path)
        let modified = attributes[.modificationDate] as? Date
        let created = attributes[.creationDate] as? Date
        print("DEVICE download date: phone \(item.modified), Mac modified \(String(describing: modified)), created \(String(describing: created))")
        #expect(modified == item.modified)
        #expect(created == item.modified)
    }

    private static func openSession() async throws -> any DeviceSession {
        let client = ADBClient(launcher: ADBServerLauncher())
        let infos = try await client.trackDevices().first { _ in true } ?? []
        let info = try #require(infos.first { $0.deviceState == .online })
        let device = Device(id: info.serial, name: info.model, model: info.model, state: .online, transport: .adb)
        return try await ADBTransport(client: client).openSession(device)
    }

    private static func engine(_ session: any DeviceSession) -> TransferEngine {
        TransferEngine(
            sessions: SessionSource(get: { _ in session }, invalidate: {}),
            options: TransferOptions(conflictPolicy: .keepBoth, parallelism: 1, scanMediaAfterUpload: false, dates: .keepOriginal),
            control: TransferControl(),
            counter: ByteCounter(),
            conflicts: ConflictArbiter { _ in (.skip, .thisItem) },
            onFileStarted: { _ in },
            onFileFinished: { _ in }
        )
    }
}
