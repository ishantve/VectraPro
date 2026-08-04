//
//  SessionSeal.swift
//  ATCReplayKit
//
//  The digest that makes an assessment evidence rather than a file.
//
//      seal = SHA256( manifest bytes ‖ every event frame, in write order )
//
//  ── Incremental, because the alternative is a stall ────────────────────────
//  Computed as events are appended rather than in one pass at the end. A forty-minute assessment ends
//  with the trainee waiting for a screen; re-reading and hashing the whole log at that moment is work
//  that can be spread across the session for nothing. One `update` per event is a few microseconds.
//
//  ── Verification recomputes it the other way ───────────────────────────────
//  A reader has the manifest and the log and no running hasher, so it hashes the file in one pass. The two
//  must agree, which is why the incremental form feeds **exactly the frame bytes as written, in order** —
//  not the decoded event, and not a re-encoding of it. Hashing anything derived would make a seal that
//  only its writer could reproduce.
//
//  ── What it is not ─────────────────────────────────────────────────────────
//  Not tamper resistance. An unkeyed digest computed on the device can be recomputed on the device after
//  an edit. It detects corruption and gives the recording a stable identity; real tamper evidence needs a
//  witness outside the device, which is the seal being submitted to the backend.
//

import Foundation
import CryptoKit

/// Builds a session's seal as its events are written.
public struct SessionSealBuilder {

    private var hasher = CryptoKit.SHA256()
    private(set) public var frameCount = 0
    private(set) public var byteCount = 0

    /// Starts a seal over `manifest`.
    ///
    /// The manifest goes in first and its length is mixed in, so a manifest and a first event cannot be
    /// rearranged into the same digest — the length prefix is what makes the concatenation unambiguous.
    public init(manifest: Data) {
        var length = UInt64(manifest.count).littleEndian
        withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
        hasher.update(data: manifest)
        byteCount = manifest.count
    }

    /// Adds one event frame, exactly as it was written to the log.
    public mutating func add(frame: Data) {
        hasher.update(data: frame)
        frameCount += 1
        byteCount += frame.count
    }

    /// The seal so far.
    ///
    /// Non-mutating, so it can be read mid-session for a progress display without ending the seal — which
    /// also means it is safe to call and discard.
    public func seal() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Verification

public enum SessionSeal {

    /// The seal a stored session should have.
    ///
    /// One pass over the log rather than frame by frame, because a reader has bytes and not a hasher. Must
    /// agree with `SessionSealBuilder` for the same session — `SessionSealTests` asserts the two forms
    /// match, since a disagreement would make every assessment unverifiable.
    public static func compute(manifest: Data, log: Data) -> String {
        var hasher = CryptoKit.SHA256()
        var length = UInt64(manifest.count).littleEndian
        withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
        hasher.update(data: manifest)
        hasher.update(data: log)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Whether a stored session still matches its seal.
    public static func verify(_ seal: String, manifest: Data, log: Data) -> Bool {
        // Compared case-insensitively so a seal that travelled through a system that upper-cased it still
        // verifies; the digest is hex, where case carries no information.
        compute(manifest: manifest, log: log).caseInsensitiveCompare(seal) == .orderedSame
    }
}
