//
//  EventStore.swift
//  ATCReplayKit
//
//  The append-only log. The only authoritative record of a session.
//
//  ── The frame is the crash recovery ────────────────────────────────────────
//  Each event is written as a length-prefixed, checksummed frame:
//
//      magic  UInt32   guards against reading a file that is not this
//      length UInt32   payload byte count
//      crc32  UInt32   over the payload
//      payload bytes
//
//  A process killed mid-write leaves a partial final frame — a length that runs past the end of the
//  file, or a checksum that does not match. Both are detectable, so recovery is "read forward until a
//  frame fails to validate, and stop there". No repair tool, no journal, no rebuild: everything before
//  the bad frame is intact and replayable.
//
//  That is the whole reason the payload is not simply a JSON array. A truncated JSON array is an
//  invalid document — one lost byte and nothing parses. A truncated frame log loses one event.
//
//  ── Durability ─────────────────────────────────────────────────────────────
//  Training batches writes; an assessment flushes every event. A lost second of practice is a lost
//  second of practice, and a lost second of an assessment is lost evidence — and at roughly a
//  thousand events a session there is no performance argument for batching an assessment.
//

import Foundation

public enum EventStoreError: Error, Equatable {
    case notWritable(String)
    case unreadable(String)
    /// The file does not begin with a valid frame — it is not an event log.
    case notAnEventLog
    /// An event was appended out of order. The log's order is its meaning, so this is refused rather
    /// than sorted out later.
    case outOfOrder(attempted: EventPosition, last: EventPosition)
}

/// Reads and appends a session's events.
///
/// Not thread-safe by design: every event passes through one gateway on one actor, and adding a lock
/// here would suggest otherwise. Ordering is the property that must be certain.
public final class EventStore {

    /// `"ATC1"`, so a file that is not an event log is rejected at the first frame rather than
    /// producing nonsense events.
    static let magic: UInt32 = 0x41544331

    public let url: URL
    public let sessionClass: SessionClass

    private let coder = EventCoder()
    private var handle: FileHandle?

    /// Events written but not yet flushed. Always empty for an assessment.
    private var pending: [Data] = []

    /// The last position accepted, so out-of-order appends can be refused.
    public private(set) var lastPosition: EventPosition?

    /// Events accepted since the store opened.
    public private(set) var count: Int = 0

    public init(url: URL, sessionClass: SessionClass) {
        self.url = url
        self.sessionClass = sessionClass
    }

    deinit {
        try? flush()
        try? handle?.close()
    }

    // MARK: - Writing

    /// Opens the log for appending, creating it if needed.
    ///
    /// Reads what is already there to recover `lastPosition`, so reopening an existing log — after a
    /// crash, or to continue a session — cannot accept an event that goes backwards.
    public func openForAppending() throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try manager.createDirectory(at: url.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
            guard manager.createFile(atPath: url.path, contents: nil) else {
                throw EventStoreError.notWritable(url.path)
            }
        } else {
            let existing = try readAll()
            lastPosition = existing.last?.position
            count = existing.count
        }

        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw EventStoreError.notWritable(url.path)
        }
        try handle.seekToEnd()
        self.handle = handle
    }

    /// Appends one event.
    ///
    /// Refuses an event that would go backwards. The log's order *is* its meaning — a replay walks it
    /// forward — so an out-of-order append is a programming error to surface now, not a mess to sort
    /// out at read time.
    public func append(_ event: Event) throws {
        if let last = lastPosition, event.position <= last {
            throw EventStoreError.outOfOrder(attempted: event.position, last: last)
        }
        guard handle != nil else { throw EventStoreError.notWritable(url.path) }

        pending.append(Self.frame(try coder.encode(event)))
        lastPosition = event.position
        count += 1

        if sessionClass.flushesEveryEvent { try flush() }
    }

    /// Writes anything buffered to the file.
    ///
    /// Called per event for an assessment, and on close or at the caller's cadence for training.
    public func flush() throws {
        guard let handle, !pending.isEmpty else { return }
        var buffer = Data()
        for frame in pending { buffer.append(frame) }
        pending.removeAll(keepingCapacity: true)
        try handle.write(contentsOf: buffer)
        // Ask the OS to put it on the device, not merely in its cache. This is what makes the
        // per-event promise for an assessment mean anything.
        try handle.synchronize()
    }

    public func close() throws {
        try flush()
        try handle?.close()
        handle = nil
    }

    // MARK: - Reading

    /// Every valid event in the log, in order.
    ///
    /// Stops at the first frame that does not validate rather than throwing: that is exactly the
    /// shape of a log whose writer was killed, and everything before it is real. Use `recover()` to
    /// find out whether that happened.
    public func readAll() throws -> [Event] {
        try read().events
    }

    /// Events in `range` of ticks, inclusive.
    ///
    /// Currently a filter over the whole log. Fine at present sizes — a session is on the order of a
    /// thousand events — and the seam where an index goes when they get larger.
    public func events(ticks range: ClosedRange<Int>) throws -> [Event] {
        try readAll().filter { range.contains($0.tick) }
    }

    /// What a read found, including whether the log was cut short.
    public struct Recovery: Equatable, Sendable {
        public let events: [Event]
        /// Bytes after the last valid frame — a partial write from a killed process.
        public let trailingBytes: Int
        /// True when the log ends mid-frame, meaning the session was interrupted.
        public var wasTruncated: Bool { trailingBytes > 0 }
    }

    /// Reads the log and reports whether it ends cleanly.
    ///
    /// The caller decides what an interrupted session means — for training, carry on; for an
    /// assessment, it is unsealed and therefore not a valid assessment.
    public func recover() throws -> Recovery {
        try read()
    }

    /// Rewrites the log without its trailing partial frame.
    ///
    /// Separate from `recover()`, and deliberately so: reading is safe and repeated, truncating
    /// destroys bytes. Nothing should discard part of a recording as a side effect of opening it.
    @discardableResult
    public func truncateToLastValidFrame() throws -> Int {
        let result = try read()
        guard result.trailingBytes > 0 else { return 0 }

        let data = try Data(contentsOf: url)
        let keep = data.count - result.trailingBytes
        try data.prefix(keep).write(to: url)
        return result.trailingBytes
    }

    // MARK: - Framing

    private static func frame(_ payload: Data) -> Data {
        var frame = Data()
        frame.append(contentsOf: bytes(magic))
        frame.append(contentsOf: bytes(UInt32(payload.count)))
        frame.append(contentsOf: bytes(CRC32.checksum(payload)))
        frame.append(payload)
        return frame
    }

    /// Little-endian, explicitly. Not the host's order — a recording may be read on a different
    /// machine, and "whatever this CPU does" is not a format.
    private static func bytes(_ value: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value),
         UInt8(truncatingIfNeeded: value >> 8),
         UInt8(truncatingIfNeeded: value >> 16),
         UInt8(truncatingIfNeeded: value >> 24)]
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private static let headerSize = 12   // magic + length + crc

    private func read() throws -> Recovery {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Recovery(events: [], trailingBytes: 0)
        }
        guard let data = try? Data(contentsOf: url) else {
            throw EventStoreError.unreadable(url.path)
        }
        if data.isEmpty { return Recovery(events: [], trailingBytes: 0) }

        var events: [Event] = []
        var offset = 0

        while offset + Self.headerSize <= data.count {
            let frameStart = offset
            guard Self.readUInt32(data, at: offset) == Self.magic else {
                // A bad magic at the very first frame means this is not an event log at all, which is
                // a different problem from a log that was cut short and deserves a different answer.
                if offset == 0 { throw EventStoreError.notAnEventLog }
                break
            }
            let length = Int(Self.readUInt32(data, at: offset + 4))
            let crc = Self.readUInt32(data, at: offset + 8)
            let payloadStart = offset + Self.headerSize

            // A length running past the end is the classic half-written frame.
            guard payloadStart + length <= data.count else { offset = frameStart; break }

            let payload = data.subdata(in: payloadStart..<(payloadStart + length))
            guard CRC32.checksum(payload) == crc else { offset = frameStart; break }
            guard let event = try? coder.decode(payload) else { offset = frameStart; break }

            events.append(event)
            offset = payloadStart + length
        }

        return Recovery(events: events, trailingBytes: data.count - offset)
    }
}

// MARK: - CRC32

/// CRC32, so a half-written frame is detectable.
///
/// Not a hash for integrity against tampering — that is the session seal's job. This catches a
/// truncated or corrupted write, which is what a killed process leaves behind.
enum CRC32 {

    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1 == 1) ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
