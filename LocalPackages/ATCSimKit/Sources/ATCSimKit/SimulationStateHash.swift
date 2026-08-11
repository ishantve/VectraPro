//
//  SimulationStateHash.swift
//  ATCSimKit
//
//  A short fingerprint of the simulation's state, for telling whether two runs agree.
//
//  Determinism is an invariant, and an invariant nobody checks decays. This is the check: run the
//  same exercise twice, or replay a recorded one, and compare fingerprints. Where they differ, the
//  simulation diverged — which is worth knowing, because the alternative is a replay that looks
//  plausible and is wrong.
//
//  ── Why it is quantised ────────────────────────────────────────────────────
//  Values are rounded before hashing, deliberately. Double arithmetic is bit-reproducible for the
//  same binary on the same architecture, but `sin`, `cos` and `atan2` may differ in their last bits
//  between architectures — an aircraft's position computed on an arm64 device and in an x86_64
//  simulator can disagree by a fraction of a nanometre. Comparing raw bits would report that as
//  divergence, which is true and useless.
//
//  So positions are compared to about a tenth of a metre and angles to a hundredth of a degree:
//  far finer than anything the simulation acts on — the tightest threshold in it is a 1 NM capture
//  radius, some ten thousand times coarser — and far coarser than floating-point noise. A
//  difference this catches is a real difference in behaviour.
//
//  Not cryptographic, and not a seal: this answers "did these two runs agree", not "has this file
//  been altered".
//

import Foundation

/// A fingerprint of one moment of simulation state.
public struct StateHash: Equatable, Hashable, Sendable, CustomStringConvertible {

    public let tick: Int
    public let value: UInt64
    /// How many aircraft went into it. Carried separately because a count mismatch is the most
    /// common kind of divergence and the most useful thing to see first.
    public let aircraftCount: Int

    public var description: String {
        "tick \(tick): \(String(format: "%016llx", value)) (\(aircraftCount) aircraft)"
    }

    /// Fingerprints the state that matters: where every aircraft is and what it is doing.
    ///
    /// `radar` and `hangar` are hashed separately rather than concatenated, so an aircraft moving
    /// between them — a hold captured, a departure rolling — changes the fingerprint. That
    /// transition is exactly the sort of thing a divergence shows up as.
    public init(clock: SimulationClock, radar: [Aircraft], hangar: [Aircraft]) {
        tick = clock.tick
        aircraftCount = radar.count + hangar.count

        var hash = Hasher.seed
        hash = Hasher.mix(hash, UInt64(bitPattern: Int64(clock.tick)))
        hash = Hasher.mix(hash, UInt64(radar.count))
        hash = Hasher.mix(hash, UInt64(hangar.count))

        // Sorted by id so the fingerprint does not depend on array order. Two runs that produced
        // the same aircraft in a different order have not diverged in any way that matters, and a
        // fingerprint that said otherwise would cry wolf.
        for aircraft in (radar + hangar).sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            hash = Hasher.mix(hash, aircraft)
        }
        value = hash
    }

    // MARK: - Mixing

    /// FNV-1a style mixing. Chosen for being short, order-sensitive, and identical everywhere —
    /// notably *not* Swift's `Hasher`, which is randomly seeded per process and would give a
    /// different answer on every run, defeating the entire purpose.
    private enum Hasher {

        static let seed: UInt64 = 0xCBF2_9CE4_8422_2325
        private static let prime: UInt64 = 0x0000_0100_0000_01B3

        static func mix(_ hash: UInt64, _ value: UInt64) -> UInt64 {
            var result = hash
            // Byte at a time, so the result depends on every byte rather than only the low ones.
            for shift in stride(from: 0, to: 64, by: 8) {
                result = (result ^ ((value >> UInt64(shift)) & 0xFF)) &* prime
            }
            return result
        }

        /// One aircraft's simulation-relevant state.
        ///
        /// Excludes `history` (a derived trail), the label offsets and the collider dimensions —
        /// none of which the simulation reads to decide anything. Including them would make the
        /// fingerprint sensitive to presentation, and a presentation change would then look like
        /// a divergence.
        static func mix(_ hash: UInt64, _ aircraft: Aircraft) -> UInt64 {
            var h = hash
            h = mix(h, string: aircraft.callsign)

            // Position to ~1e-6 degrees ≈ 0.11 m.
            h = mix(h, quantised: aircraft.position.latitude, scale: 1_000_000)
            h = mix(h, quantised: aircraft.position.longitude, scale: 1_000_000)

            // Angles to 0.01°, speeds to 0.01 kt, altitudes to 0.01 ft.
            h = mix(h, quantised: aircraft.headingDegrees, scale: 100)
            h = mix(h, quantised: aircraft.speedKnots, scale: 100)
            h = mix(h, quantised: aircraft.altitudeFeet, scale: 100)

            // Intent, not just state: two aircraft in the same place turning different ways have
            // not converged.
            h = mix(h, optional: aircraft.targetHeading, scale: 100)
            h = mix(h, optional: aircraft.targetSpeedKnots, scale: 100)
            h = mix(h, optional: aircraft.targetAltitudeFeet, scale: 100)

            // Mode flags — what the aircraft is doing, which drives every guidance service.
            h = mix(h, string: aircraft.holdingName ?? "")
            h = mix(h, string: aircraft.holdingTargetName ?? "")
            h = mix(h, string: aircraft.directToFix ?? "")
            h = mix(h, string: aircraft.interceptRunway ?? "")
            h = mix(h, string: aircraft.assignedRunway ?? "")
            h = mix(h, string: aircraft.pendingTakeoffRunway ?? "")
            h = mix(h, string: aircraft.squawk)
            h = mix(h, UInt64(aircraft.takeoffState == nil ? 0 : 1))
            h = mix(h, quantised: aircraft.holdingProgress, scale: 100)
            return h
        }

        static func mix(_ hash: UInt64, quantised value: Double, scale: Double) -> UInt64 {
            // A non-finite value is hashed as a distinct constant rather than crashing the
            // conversion: NaN in the state is itself a bug, and it should show as a divergence
            // rather than as a trap inside the check that was meant to find it.
            guard value.isFinite else { return mix(hash, 0xDEAD_BEEF_DEAD_BEEF) }
            return mix(hash, UInt64(bitPattern: Int64((value * scale).rounded())))
        }

        static func mix(_ hash: UInt64, optional value: Double?, scale: Double) -> UInt64 {
            guard let value else { return mix(hash, 0xFFFF_FFFF_FFFF_FFFF) }  // absent ≠ zero
            return mix(hash, quantised: value, scale: scale)
        }

        static func mix(_ hash: UInt64, string: String) -> UInt64 {
            var h = hash
            for byte in string.utf8 { h = mix(h, UInt64(byte)) }
            return mix(h, 0)   // terminator, so "ab" + "c" differs from "a" + "bc"
        }
    }
}
