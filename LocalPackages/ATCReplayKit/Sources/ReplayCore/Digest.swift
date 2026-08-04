//
//  Digest.swift
//  ATCReplayKit
//
//  Hashing for the two places a recording needs to prove it is unchanged: the embedded exercise
//  payload, and an assessment's seal.
//
//  A one-type seam over CryptoKit rather than a direct dependency scattered through the package. Two
//  reasons: the algorithm is part of a stored format, so where it is decided should be one obvious
//  place; and CryptoKit is Apple-only, so if this package is ever ported the substitution is confined
//  to this file.
//
//  ── What a digest here does and does not buy ────────────────────────────────
//  It detects corruption and accidental modification, and gives a recording a stable identity for
//  sharing and comparison. It is **not** tamper resistance: an unkeyed digest computed on the device
//  can be recomputed on the device after an edit. Real tamper evidence needs a witness outside the
//  device — the seal submitted to and stored by the backend — and pretending otherwise would be the
//  dishonest kind of security.
//

import Foundation
import CryptoKit

/// SHA-256, hex-encoded.
public enum SHA256 {

    /// The raw digest, for callers that need bytes rather than hex — deriving an id, for instance.
    ///
    /// Here rather than beside its caller so `CryptoKit` stays imported in exactly one file. An
    /// `@_exported import` would have leaked it into every consumer of this package.
    static func bytes(_ data: Data) -> [UInt8] {
        Array(CryptoKit.SHA256.hash(data: data))
    }

    /// Hex digest of `data`. Lowercase, no separators — the form that goes into a manifest.
    public static func hex(_ data: Data) -> String {
        CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Hex digest of several pieces, in order.
    ///
    /// Order matters and length is mixed in: without the length prefix, `["ab", "c"]` and
    /// `["a", "bc"]` would hash identically, so two different recordings could claim the same seal.
    public static func hex(_ pieces: [Data]) -> String {
        var hasher = CryptoKit.SHA256()
        for piece in pieces {
            var length = UInt64(piece.count).littleEndian
            withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
            hasher.update(data: piece)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
