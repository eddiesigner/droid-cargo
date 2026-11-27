@testable import CargoServices
import DeviceKit
import Foundation
import Testing

@MainActor
struct PlaceOperationTests {
    private func operation(_ session: FakeSession, _ policy: ConflictPolicy, _ mode: PlaceMode = .move) -> PlaceOperation {
        let arbiter = ConflictArbiter { _ in (.skip, .thisItem) }
        return PlaceOperation(session: session, conflicts: arbiter, policy: policy, mode: mode)
    }

    private func session(_ files: [String]) async throws -> FakeSession {
        let session = FakeSession()
        try await session.makeDirectory("/sdcard/DCIM")
        try await session.makeDirectory("/sdcard/Pictures")
        for path in files {
            session.put(path, data: Data(path.utf8))
        }
        return session
    }

    @Test func movesIntoFolder() async throws {
        let fake = try await session(["/sdcard/DCIM/a.jpg"])
        let moved = try await operation(fake, .ask).run(["/sdcard/DCIM/a.jpg"], into: "/sdcard/Pictures")

        #expect(moved.map(\.to) == ["/sdcard/Pictures/a.jpg"])
        #expect(try await fake.stat("/sdcard/Pictures/a.jpg") != nil)
        #expect(try await fake.stat("/sdcard/DCIM/a.jpg") == nil)
    }

    @Test func keepBothPicksNumberedName() async throws {
        let fake = try await session(["/sdcard/DCIM/a.jpg", "/sdcard/Pictures/a.jpg"])
        let moved = try await operation(fake, .keepBoth).run(["/sdcard/DCIM/a.jpg"], into: "/sdcard/Pictures")

        #expect(moved.map(\.to) == ["/sdcard/Pictures/a 2.jpg"])
        #expect(try await fake.stat("/sdcard/Pictures/a.jpg") != nil)
    }

    @Test func skipLeavesBothInPlace() async throws {
        let fake = try await session(["/sdcard/DCIM/a.jpg", "/sdcard/Pictures/a.jpg"])
        let moved = try await operation(fake, .skip).run(["/sdcard/DCIM/a.jpg"], into: "/sdcard/Pictures")

        #expect(moved.isEmpty)
        #expect(try await fake.stat("/sdcard/DCIM/a.jpg") != nil)
    }

    @Test func replaceOverwrites() async throws {
        let fake = try await session(["/sdcard/DCIM/a.jpg", "/sdcard/Pictures/a.jpg"])
        _ = try await operation(fake, .replace).run(["/sdcard/DCIM/a.jpg"], into: "/sdcard/Pictures")

        #expect(fake.data("/sdcard/Pictures/a.jpg") == Data("/sdcard/DCIM/a.jpg".utf8))
        #expect(try await fake.stat("/sdcard/DCIM/a.jpg") == nil)
    }

    @Test func itemAlreadyInFolderIsLeftAlone() async throws {
        let fake = try await session(["/sdcard/Pictures/a.jpg"])
        let moved = try await operation(fake, .keepBoth).run(["/sdcard/Pictures/a.jpg"], into: "/sdcard/Pictures")

        #expect(moved.isEmpty)
        #expect(try await fake.stat("/sdcard/Pictures/a 2.jpg") == nil)
    }

    @Test func folderIntoItsOwnSubfolderFails() async throws {
        let fake = try await session([])
        try await fake.makeDirectory("/sdcard/DCIM/Camera")

        await #expect(throws: MoveError.intoItself("DCIM")) {
            try await operation(fake, .ask).run(["/sdcard/DCIM"], into: "/sdcard/DCIM/Camera")
        }
    }

    @Test func copyKeepsOriginal() async throws {
        let fake = try await session(["/sdcard/DCIM/a.jpg"])
        let copied = try await operation(fake, .ask, .copy).run(["/sdcard/DCIM/a.jpg"], into: "/sdcard/Pictures")

        #expect(copied.map(\.to) == ["/sdcard/Pictures/a.jpg"])
        #expect(try await fake.stat("/sdcard/DCIM/a.jpg") != nil)
        #expect(try await fake.stat("/sdcard/Pictures/a.jpg") != nil)
    }

    @Test func copyIntoSameFolderDuplicates() async throws {
        let fake = try await session(["/sdcard/Pictures/a.jpg", "/sdcard/Pictures/a 2.jpg"])
        let copied = try await operation(fake, .skip, .copy).run(["/sdcard/Pictures/a.jpg"], into: "/sdcard/Pictures")

        #expect(copied.map(\.to) == ["/sdcard/Pictures/a 3.jpg"])
    }
}
