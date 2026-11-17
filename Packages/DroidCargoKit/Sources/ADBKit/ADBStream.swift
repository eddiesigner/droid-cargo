import DeviceKit
import Foundation
import Network
import Synchronization

/// Byte stream to the local adb server. Abstracted so tests can script replies.
public protocol ADBStream: AnyObject, Sendable {
    func write(_ data: Data) async throws
    func read(exactly count: Int) async throws -> Data
    func readToEnd() async throws -> Data
    func close()
}

/// TCP connection to the adb server (default 127.0.0.1:5037).
///
/// Single reader, single writer: callers must not issue concurrent reads.
public final class ADBSocket: ADBStream, @unchecked Sendable {
    private static let receiveChunk = 256 * 1024

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "app.droidcargo.adb.socket")
    /// Received bytes; `readOffset` marks how far callers have consumed.
    /// Consuming by offset avoids shifting the whole buffer on every small read.
    private var buffer = Data()
    private var readOffset = 0
    private var reachedEnd = false

    public init(port: UInt16) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port)!,
            using: NWParameters(tls: nil, tcp: tcp)
        )
    }

    public func open() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = Mutex(false)
            connection.stateUpdateHandler = { state in
                let result: Result<Void, Error>?
                switch state {
                case .ready:
                    result = .success(())
                case .failed(let error), .waiting(let error):
                    result = .failure(DeviceError.transportUnavailable(error.localizedDescription))
                case .cancelled:
                    result = .failure(DeviceError.deviceDisconnected)
                default:
                    result = nil
                }
                guard let result else {
                    return
                }
                let first = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first {
                    continuation.resume(with: result)
                }
            }
            connection.start(queue: queue)
        }
    }

    public func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: DeviceError.transportUnavailable(error.localizedDescription))
                    return
                }
                continuation.resume()
            })
        }
    }

    public func read(exactly count: Int) async throws -> Data {
        while buffer.count - readOffset < count {
            guard try await receiveMore() else {
                throw DeviceError.deviceDisconnected
            }
        }
        let start = buffer.startIndex + readOffset
        let result = Data(buffer[start..<start + count])
        readOffset += count
        return result
    }

    public func readToEnd() async throws -> Data {
        while try await receiveMore() {}
        let rest = Data(buffer.dropFirst(readOffset))
        buffer.removeAll()
        readOffset = 0
        return rest
    }

    public func close() {
        connection.cancel()
    }

    /// Appends the next chunk to the buffer. Returns false at end of stream.
    private func receiveMore() async throws -> Bool {
        if reachedEnd {
            return false
        }
        let (data, isComplete): (Data?, Bool) = try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: Self.receiveChunk) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: DeviceError.transportUnavailable(error.localizedDescription))
                    return
                }
                continuation.resume(returning: (data, isComplete))
            }
        }
        if let data, !data.isEmpty {
            // Drop consumed bytes only when appending, at most once per network chunk.
            if readOffset > 0 {
                buffer.removeFirst(readOffset)
                readOffset = 0
            }
            buffer.append(data)
        }
        if isComplete {
            reachedEnd = true
        }
        return !(data?.isEmpty ?? true) || !isComplete
    }
}
