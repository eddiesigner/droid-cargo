import DeviceKit
import Foundation

public enum ConflictPolicy: String, CaseIterable, Sendable {
    case ask
    case skip
    case replace
    case keepBoth
}

public enum ConflictResolution: Sendable {
    case skip
    case replace
    case keepBoth
}

public enum ConflictScope: Sendable {
    case thisItem
    case allRemaining
}

public struct TransferConflict: Sendable {
    public let name: String
    public let direction: TransferDirection
}

public struct TransferOptions: Sendable {
    public var conflictPolicy: ConflictPolicy
    /// Files moved at the same time. More than one hides per-file latency for small files.
    public var parallelism: Int
    public var scanMediaAfterUpload: Bool

    public init(conflictPolicy: ConflictPolicy, parallelism: Int, scanMediaAfterUpload: Bool) {
        self.conflictPolicy = conflictPolicy
        self.parallelism = max(1, parallelism)
        self.scanMediaAfterUpload = scanMediaAfterUpload
    }
}

/// Asks the user how to resolve a name clash.
public typealias ConflictHandler = @MainActor (TransferConflict) async -> (ConflictResolution, ConflictScope)

/// Where a single file comes from and goes to.
enum PlannedFile: Sendable {
    case download(remotePath: String, size: UInt64, modified: Date, localURL: URL)
    case upload(localURL: URL, size: UInt64, modified: Date, remotePath: String)

    var size: UInt64 {
        switch self {
        case .download(_, let size, _, _), .upload(_, let size, _, _):
            return size
        }
    }

    var name: String {
        switch self {
        case .download(let remotePath, _, _, _):
            return RemotePath.name(remotePath)
        case .upload(let localURL, _, _, _):
            return localURL.lastPathComponent
        }
    }
}

enum FileOutcome: Sendable {
    case transferred(PlannedFile, finalPath: String)
    case skipped(PlannedFile)
    case failed(PlannedFile, String)
}

/// Provides sessions to the engine and resets them after connection errors.
struct SessionSource: Sendable {
    let get: @Sendable (ReconnectPolicy) async throws -> any DeviceSession
    let invalidate: @Sendable () async -> Void
}

/// Runs one job's files with bounded parallelism, retries and atomic finalization.
///
///   plan ──▶ [worker 1] ─┐
///            [worker 2] ─┼─▶ temp file ─▶ verify size ─▶ rename into place
///            [worker N] ─┘
struct TransferEngine: Sendable {
    static let maxAttempts = 3
    static let tempSuffix = ".droidcargo-part"
    /// Mac files never worth copying to a phone.
    static let ignoredLocalNames: Set<String> = [".DS_Store", ".localized"]

    let sessions: SessionSource
    let options: TransferOptions
    let control: TransferControl
    let counter: ByteCounter
    let conflicts: ConflictArbiter
    let onFileStarted: @Sendable (String) async -> Void
    let onFileFinished: @Sendable (FileOutcome) async -> Void

    // MARK: Planning

    /// Expands folders into files and creates the destination folder tree.
    static func planDownload(
        _ requests: [(RemoteItem, URL)],
        session: any DeviceSession,
        onFound: @Sendable (Int, UInt64) async -> Void
    ) async throws -> [PlannedFile] {
        var files: [PlannedFile] = []
        var totalBytes: UInt64 = 0
        var pending: [(RemoteItem, URL)] = requests

        while let (item, folder) = pending.popLast() {
            try Task.checkCancellation()
            let target = folder.appending(path: item.name, directoryHint: item.isDirectory ? .isDirectory : .notDirectory)
            guard item.isDirectory else {
                files.append(.download(remotePath: item.path, size: item.size, modified: item.modified, localURL: target))
                totalBytes += item.size
                continue
            }
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let children = try await session.list(item.path)
            pending.append(contentsOf: children.map { ($0, target) })
            await onFound(files.count, totalBytes)
        }
        await onFound(files.count, totalBytes)
        return files
    }

    /// Expands Mac folders into files and creates the matching folders on the phone.
    static func planUpload(
        _ urls: [URL],
        to remoteFolder: String,
        session: any DeviceSession,
        onFound: @Sendable (Int, UInt64) async -> Void
    ) async throws -> [PlannedFile] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        var files: [PlannedFile] = []
        var folders: [String] = []
        var totalBytes: UInt64 = 0

        func add(_ url: URL, remotePath: String) throws {
            guard !ignoredLocalNames.contains(url.lastPathComponent) else {
                return
            }
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isDirectory == true {
                folders.append(remotePath)
                return
            }
            let size = UInt64(values.fileSize ?? 0)
            files.append(.upload(localURL: url, size: size, modified: values.contentModificationDate ?? Date(), remotePath: remotePath))
            totalBytes += size
        }

        for url in urls {
            try Task.checkCancellation()
            let root = RemotePath.join(remoteFolder, url.lastPathComponent)
            try add(url, remotePath: root)
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else {
                continue
            }
            let base = url.standardizedFileURL.path
            while let child = enumerator.nextObject() as? URL {
                let relative = String(child.standardizedFileURL.path.dropFirst(base.count + 1))
                try add(child, remotePath: RemotePath.join(root, relative))
                if files.count.isMultiple(of: 500) {
                    await onFound(files.count, totalBytes)
                }
            }
        }

        // Parents first so `mkdir` never races a file upload.
        for folder in folders.sorted() {
            try await session.makeDirectory(folder)
        }
        await onFound(files.count, totalBytes)
        return files
    }

    // MARK: Execution

    func run(_ files: [PlannedFile]) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = files.makeIterator()

            // Keep `parallelism` workers busy; start the next file when one finishes.
            for _ in 0..<options.parallelism {
                guard let file = iterator.next() else {
                    break
                }
                group.addTask { await onFileFinished(try await process(file)) }
            }
            while try await group.next() != nil {
                guard let file = iterator.next() else {
                    continue
                }
                group.addTask { await onFileFinished(try await process(file)) }
            }
        }
    }

    private func process(_ file: PlannedFile) async throws -> FileOutcome {
        try await control.checkpoint()
        guard let destination = try await resolveDestination(file) else {
            return .skipped(file)
        }

        await onFileStarted(file.name)
        var lastError: Error?
        for attempt in 1...Self.maxAttempts {
            let fileBytes = ByteCounter()
            do {
                let session = try await sessions.get(attempt == 1 ? .immediate : .waitForDevice)
                try await transfer(file, to: destination, session: session) { bytes in
                    fileBytes.add(bytes)
                    counter.add(bytes)
                }
                return .transferred(file, finalPath: destination)
            } catch is CancellationError {
                counter.subtract(fileBytes.value)
                throw CancellationError()
            } catch let error as DeviceError where error.isTransient && attempt < Self.maxAttempts {
                // Roll back partial progress and try again on a fresh connection.
                counter.subtract(fileBytes.value)
                lastError = error
                await sessions.invalidate()
                try await Task.sleep(for: .seconds(attempt))
            } catch {
                counter.subtract(fileBytes.value)
                lastError = error
                break
            }
        }
        return .failed(file, lastError?.localizedDescription ?? String(localized: "Unknown error"))
    }

    /// Applies the conflict policy. Returns nil when the file should be skipped.
    private func resolveDestination(_ file: PlannedFile) async throws -> String? {
        switch file {
        case .download(_, _, _, let localURL):
            guard FileManager.default.fileExists(atPath: localURL.path) else {
                return localURL.path
            }
            switch await conflicts.resolve(TransferConflict(name: file.name, direction: .toMac), policy: options.conflictPolicy) {
            case .skip:
                return nil
            case .replace:
                return localURL.path
            case .keepBoth:
                return Self.uniqueName(for: localURL.path) { FileManager.default.fileExists(atPath: $0) }
            }

        case .upload(_, _, _, let remotePath):
            let session = try await sessions.get(.immediate)
            guard try await session.stat(remotePath) != nil else {
                return remotePath
            }
            switch await conflicts.resolve(TransferConflict(name: file.name, direction: .toDevice), policy: options.conflictPolicy) {
            case .skip:
                return nil
            case .replace:
                return remotePath
            case .keepBoth:
                var candidate = remotePath
                var number = 2
                while try await session.stat(candidate) != nil {
                    candidate = Self.numbered(remotePath, number)
                    number += 1
                }
                return candidate
            }
        }
    }

    private func transfer(_ file: PlannedFile, to destination: String, session: any DeviceSession, progress: @escaping ByteProgress) async throws {
        switch file {
        case .download(let remotePath, let size, let modified, _):
            try await download(remotePath, size: size, modified: modified, to: URL(filePath: destination), session: session, progress: progress)
        case .upload(let localURL, let size, let modified, _):
            try await upload(localURL, size: size, modified: modified, to: destination, session: session, progress: progress)
        }
    }

    /// Writes to a hidden temp file and renames it only after the size checks out,
    /// so an interrupted copy never leaves a truncated file behind.
    private func download(_ remotePath: String, size: UInt64, modified: Date, to target: URL, session: any DeviceSession, progress: @escaping ByteProgress) async throws {
        let folder = target.deletingLastPathComponent()
        let temp = folder.appending(path: ".\(target.lastPathComponent).\(UUID().uuidString)\(Self.tempSuffix)")
        defer { try? FileManager.default.removeItem(at: temp) }

        try await session.download(remotePath, to: temp, control: control, progress: progress)

        let written = try FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? UInt64 ?? 0
        guard written == size else {
            throw DeviceError.protocolViolation(String(localized: "expected \(size) bytes, received \(written)"))
        }
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: temp.path)
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
            return
        }
        try FileManager.default.moveItem(at: temp, to: target)
    }

    private func upload(_ localURL: URL, size: UInt64, modified: Date, to remotePath: String, session: any DeviceSession, progress: @escaping ByteProgress) async throws {
        let folder = RemotePath.parent(remotePath)
        let temp = RemotePath.join(folder, ".\(RemotePath.name(remotePath))\(Self.tempSuffix)")

        do {
            try await session.upload(localURL, to: temp, modified: modified, control: control, progress: progress)
            guard let uploaded = try await session.stat(temp), uploaded.size == size else {
                throw DeviceError.protocolViolation(String(localized: "size mismatch after upload"))
            }
            try await session.move(temp, to: remotePath)
        } catch {
            try? await session.remove(temp)
            throw error
        }
    }

    // MARK: Naming

    /// "photo.jpg" -> "photo 2.jpg", "photo 3.jpg", ...
    static func numbered(_ path: String, _ number: Int) -> String {
        let nsPath = path as NSString
        let ext = nsPath.pathExtension
        let stem = (nsPath.lastPathComponent as NSString).deletingPathExtension
        let name = ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)"
        return (nsPath.deletingLastPathComponent as NSString).appendingPathComponent(name)
    }

    static func uniqueName(for path: String, exists: (String) -> Bool) -> String {
        var number = 2
        var candidate = numbered(path, number)
        while exists(candidate) {
            number += 1
            candidate = numbered(path, number)
        }
        return candidate
    }
}

/// Serializes conflict prompts across workers and remembers "apply to all".
actor ConflictArbiter {
    private let handler: ConflictHandler
    private var remembered: ConflictResolution?
    private var isAsking = false

    init(handler: @escaping ConflictHandler) {
        self.handler = handler
    }

    func resolve(_ conflict: TransferConflict, policy: ConflictPolicy) async -> ConflictResolution {
        switch policy {
        case .skip:
            return .skip
        case .replace:
            return .replace
        case .keepBoth:
            return .keepBoth
        case .ask:
            // Actor methods re-enter at `await`; wait so only one prompt shows at a time.
            while isAsking {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if let remembered {
                return remembered
            }
            isAsking = true
            defer { isAsking = false }
            let (resolution, scope) = await handler(conflict)
            if scope == .allRemaining {
                remembered = resolution
            }
            return resolution
        }
    }
}
