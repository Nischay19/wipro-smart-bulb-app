import CryptoKit
import Foundation
import Network

/// A datapoint value as the bulb sends and accepts it.
public enum DPValue: Sendable, Equatable, CustomStringConvertible {
    case bool(Bool)
    case int(Int)
    case string(String)

    init?(json: Any) {
        switch json {
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): self = .bool(n.boolValue)
        case let n as NSNumber: self = .int(n.intValue)
        case let s as String: self = .string(s)
        default: return nil
        }
    }

    var json: Any {
        switch self {
        case .bool(let b): b
        case .int(let i): i
        case .string(let s): s
        }
    }

    public var description: String {
        switch self {
        case .bool(let b): String(b)
        case .int(let i): String(i)
        case .string(let s): "\"\(s)\""
        }
    }
}

public typealias DPS = [String: DPValue]

/// One encrypted LAN session with a protocol-3.5 Tuya device.
///
/// `connect()` opens TCP 6668 and negotiates a session key; afterwards a reader loop publishes every
/// datapoint update the device sends (replies to our commands and changes made elsewhere) on `updates`.
public actor TuyaConnection {
    public nonisolated let host: String
    public nonisolated let deviceID: String
    public nonisolated let updates: AsyncStream<DPS>

    private let port: UInt16
    private let localKey: [UInt8]
    private let queue = DispatchQueue(label: "glow.tuya")
    private let continuation: AsyncStream<DPS>.Continuation
    private var conn: NWConnection?
    private var sessionKey: SymmetricKey?
    private var seq: UInt32 = 1
    private var readerTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var connecting: Task<Void, Error>?

    public init(host: String, deviceID: String, localKey: String, port: UInt16 = 6668) throws {
        let key = Array(localKey.utf8)
        guard key.count == 16 else { throw TuyaError.invalidKey }
        self.host = host
        self.deviceID = deviceID
        self.localKey = key
        self.port = port
        (updates, continuation) = AsyncStream.makeStream(of: DPS.self, bufferingPolicy: .bufferingNewest(32))
    }

    public var isConnected: Bool { sessionKey != nil }

    /// Connects and negotiates a session key. Safe to call repeatedly; concurrent callers share one attempt.
    public func connect() async throws {
        if sessionKey != nil { return }
        if let connecting { return try await connecting.value }
        let task = Task { try await self.openSession() }
        connecting = task
        defer { connecting = nil }
        try await task.value
    }

    public func disconnect() {
        readerTask?.cancel()
        heartbeatTask?.cancel()
        conn?.cancel()
        conn = nil
        sessionKey = nil
    }

    /// Asks the device for all datapoints; the answer arrives on `updates`.
    public func query() async throws {
        try await sendWithReconnect(.dpQueryNew, json: [:])
    }

    /// Writes datapoints, e.g. `["20": .bool(true)]`.
    public func set(_ dps: DPS) async throws {
        let body: [String: Any] = ["protocol": 5, "t": Int(Date().timeIntervalSince1970),
                                   "data": ["dps": dps.mapValues(\.json)]]
        try await sendWithReconnect(.controlNew, json: body)
    }

    /// Convenience for one-shot callers (the CLI): query and wait for the first full status.
    /// Don't combine with another consumer of `updates`; an AsyncStream has a single reader.
    public func status(timeout: TimeInterval = 3) async throws -> DPS {
        try await connect()
        let stream = updates
        let waiter = Task { () -> DPS? in
            for await dps in stream where dps.count > 2 { return dps }
            return nil
        }
        defer { waiter.cancel() }
        try await query()
        guard let dps = try await withThrowingTimeout(timeout, { await waiter.value }) else { throw TuyaError.timeout }
        return dps
    }

    // MARK: - Session

    private func openSession() async throws {
        disconnect()
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        conn = c
        try await waitReady(c)

        // 1. our nonce, encrypted with the real local key
        let realKey = SymmetricKey(data: localKey)
        let localNonce = randomBytes(16)
        try await send(c, cmd: .sessionKeyStart, payload: localNonce, key: realKey)

        // 2. device nonce + proof it knows the key
        let reply: TuyaFrame
        do {
            reply = try await readFrame(c, key: realKey, timeout: 3)
        } catch TuyaError.authenticationFailed {
            disconnect(); throw TuyaError.wrongKey
        } catch {
            disconnect(); throw error
        }
        guard reply.cmd == TuyaCommand.sessionKeyResponse.rawValue, reply.payload.count >= 48 else {
            disconnect(); throw TuyaError.handshakeFailed("unexpected reply cmd \(reply.cmd), \(reply.payload.count) bytes")
        }
        let remoteNonce = Array(reply.payload[0 ..< 16])
        guard Array(reply.payload[16 ..< 48]) == TuyaSession.hmac(localKey, localNonce) else {
            disconnect(); throw TuyaError.wrongKey
        }

        // 3. our proof
        try await send(c, cmd: .sessionKeyFinish, payload: TuyaSession.hmac(localKey, remoteNonce), key: realKey)
        sessionKey = SymmetricKey(data: try TuyaSession.sessionKey(localKey: localKey, localNonce: localNonce,
                                                                    remoteNonce: remoteNonce))
        startLoops(c)
    }

    private func startLoops(_ c: NWConnection) {
        readerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let key = await self.sessionKey else { return }
                do {
                    let frame = try await self.readFrame(c, key: key, timeout: nil)
                    if let dps = Self.parseDPS(frame.payload) { self.continuation.yield(dps) }
                } catch {
                    await self.connectionLost(c)
                    return
                }
            }
        }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled else { return }
                try? await self.sendSession(.heartbeat, json: ["gwId": self.deviceID, "devId": self.deviceID])
            }
        }
    }

    private func connectionLost(_ c: NWConnection) {
        guard conn === c else { return }
        disconnect()
    }

    private func sendWithReconnect(_ cmd: TuyaCommand, json: [String: Any]) async throws {
        try await connect()
        do {
            try await sendSession(cmd, json: json)
        } catch {
            disconnect() // bulbs drop idle sockets; retry once on a fresh session
            try await connect()
            try await sendSession(cmd, json: json)
        }
    }

    private func sendSession(_ cmd: TuyaCommand, json: [String: Any]) async throws {
        guard let c = conn, let key = sessionKey else { throw TuyaError.connectionClosed }
        var payload = try [UInt8](JSONSerialization.data(withJSONObject: json))
        if !cmd.omitsVersionHeader { payload = TuyaCodec.versionHeader + payload }
        try await send(c, cmd: cmd, payload: payload, key: key)
    }

    static func parseDPS(_ payload: [UInt8]) -> DPS? {
        guard let start = payload.firstIndex(of: UInt8(ascii: "{")),
              let obj = try? JSONSerialization.jsonObject(with: Data(payload[start...])) as? [String: Any]
        else { return nil }
        let raw = (obj["dps"] ?? (obj["data"] as? [String: Any])?["dps"]) as? [String: Any]
        guard let raw else { return nil }
        return raw.compactMapValues(DPValue.init(json:))
    }

    // MARK: - Network.framework plumbing

    private func send(_ c: NWConnection, cmd: TuyaCommand, payload: [UInt8], key: SymmetricKey) async throws {
        let bytes = try TuyaCodec.encode(cmd: cmd.rawValue, seq: seq, payload: payload, key: key)
        seq &+= 1
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            c.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    private func readFrame(_ c: NWConnection, key: SymmetricKey, timeout: TimeInterval?) async throws -> TuyaFrame {
        let header = try await receive(c, exactly: TuyaCodec.headerLength, timeout: timeout)
        let total = try TuyaCodec.frameLength(header: header)
        let rest = try await receive(c, exactly: total - TuyaCodec.headerLength, timeout: timeout ?? 5)
        return try TuyaCodec.decode(header + rest, key: key)
    }

    private nonisolated func waitReady(_ c: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce(cont)
            c.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(.success(()))
                case .failed(let e), .waiting(let e): once.resume(.failure(e)); c.cancel()
                case .cancelled: once.resume(.failure(TuyaError.connectionClosed))
                default: break
                }
            }
            c.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 4) {
                if once.resume(.failure(TuyaError.timeout)) { c.cancel() }
            }
        }
    }

    private nonisolated func receive(_ c: NWConnection, exactly n: Int, timeout: TimeInterval?) async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[UInt8], Error>) in
            let once = ResumeOnce(cont)
            c.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, isComplete, error in
                if let error { once.resume(.failure(error)); return }
                guard let data, data.count == n else {
                    once.resume(.failure(isComplete ? TuyaError.connectionClosed : TuyaError.truncated)); return
                }
                once.resume(.success([UInt8](data)))
            }
            if let timeout {
                queue.asyncAfter(deadline: .now() + timeout) {
                    if once.resume(.failure(TuyaError.timeout)) { c.cancel() }
                }
            }
        }
    }
}

/// Resumes a continuation at most once (network callbacks and timeouts race).
final class ResumeOnce<T>: @unchecked Sendable {
    private var cont: CheckedContinuation<T, Error>?
    private let lock = NSLock()
    init(_ cont: CheckedContinuation<T, Error>) { self.cont = cont }

    @discardableResult
    func resume(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(with: result)
        return c != nil
    }
}

func withThrowingTimeout<T: Sendable>(_ seconds: TimeInterval, _ op: @escaping @Sendable () async -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { await op() }
        group.addTask { try await Task.sleep(for: .seconds(max(0, seconds))); return nil }
        defer { group.cancelAll() }
        guard let first = try await group.next(), let value = first else { throw TuyaError.timeout }
        return value
    }
}
