import DeviceKit
import Foundation

/// What pasting or dropping items into a folder does with them.
public enum PlaceMode: Sendable {
    case move
    case copy
}

public enum MoveError: Error, Equatable, LocalizedError {
    /// A folder dropped into itself or one of its subfolders.
    case intoItself(String)

    public var errorDescription: String? {
        switch self {
        case .intoItself(let name):
            return String(localized: "“\(name)” can’t be moved into itself.")
        }
    }
}

/// Moves or copies items into another folder on the same phone, applying
/// the conflict policy when the folder already holds an item with that name.
///
///     move /DCIM/a.jpg   ──▶ /Pictures/a.jpg      free name
///     move /DCIM/b.jpg   ──▶ /Pictures/b 2.jpg    clash, Keep Both
///     move /Pictures/c   ──▶ (nothing)            already there
///     copy /Pictures/c   ──▶ /Pictures/c 2        duplicate in place
struct PlaceOperation {
    let session: any DeviceSession
    let conflicts: ConflictArbiter
    let policy: ConflictPolicy
    let mode: PlaceMode

    /// Returns each placed item's old and new path. Checks every item before touching any.
    func run(_ paths: [String], into folder: String) async throws -> [(from: String, to: String)] {
        for path in paths where folder == path || folder.hasPrefix(path + "/") {
            throw MoveError.intoItself(RemotePath.name(path))
        }

        var placed: [(from: String, to: String)] = []
        for path in paths {
            try Task.checkCancellation()
            guard let destination = try await destination(for: path, in: folder) else {
                continue
            }
            switch mode {
            case .move:
                try await session.move(path, to: destination)
            case .copy:
                try await session.copy(path, to: destination)
            }
            placed.append((from: path, to: destination))
        }
        return placed
    }

    /// The free path to use, or nil to skip. Replace removes the existing
    /// item first: `mv`/`cp` would otherwise put a folder inside the existing one.
    private func destination(for path: String, in folder: String) async throws -> String? {
        let target = RemotePath.join(folder, RemotePath.name(path))

        // Same folder: a move is a no-op, a copy is a numbered duplicate.
        if RemotePath.parent(path) == folder {
            return mode == .copy ? try await freeNumberedPath(target) : nil
        }
        guard try await session.stat(target) != nil else {
            return target
        }
        let conflict = TransferConflict(name: RemotePath.name(path), direction: .toDevice)
        switch await conflicts.resolve(conflict, policy: policy) {
        case .skip:
            return nil
        case .replace:
            try await session.remove(target)
            return target
        case .keepBoth:
            return try await freeNumberedPath(target)
        }
    }

    private func freeNumberedPath(_ target: String) async throws -> String {
        var number = 2
        var candidate = TransferEngine.numbered(target, number)
        while try await session.stat(candidate) != nil {
            number += 1
            candidate = TransferEngine.numbered(target, number)
        }
        return candidate
    }
}
