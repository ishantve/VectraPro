//
//  GridWorld.swift
//  GridBotAdapter
//
//  The simulation itself — the world a replay reconstructs. Deterministic: the same events in the same order
//  produce the same state, which is what makes a fingerprint meaningful. Fingerprint composition is the
//  adapter's business (ReplayCore has no opinion on which fields matter), so it lives here.
//

import Foundation
import CryptoKit

/// A robot on an unbounded integer grid.
public struct GridWorld: Equatable, Sendable {

    public enum Heading: Int, Equatable, Sendable { case north = 0, east, south, west }

    public private(set) var x = 0
    public private(set) var y = 0
    public private(set) var heading: Heading = .north
    public private(set) var cargoWeight = 0
    public private(set) var moveCount = 0

    public init() {}

    /// Apply one simulation-affecting payload. Annotations and timeline actions never reach here — the caller
    /// filters them by `affectsSimulation(tag:)`, exactly as a real replay does.
    public mutating func apply(_ payload: GridBotPayload) {
        switch payload {
        case .moved(let steps):
            switch heading {
            case .north: y += steps
            case .south: y -= steps
            case .east:  x += steps
            case .west:  x -= steps
            }
            moveCount += 1
        case .turned(let dir):
            let delta = (dir == .right) ? 1 : 3        // +90° right, −90° == +270°
            heading = Heading(rawValue: (heading.rawValue + delta) % 4)!
        case .pickedUp(let weight):
            cargoWeight += weight
        case .annotated, .timeline:
            break                                       // not simulation inputs; never routed here
        }
    }

    /// A deterministic digest of the world state. Two runs that end in the same state hash identically;
    /// any divergence in position, heading, cargo or move count changes it.
    public var fingerprint: String {
        let canonical = "x=\(x);y=\(y);h=\(heading.rawValue);w=\(cargoWeight);m=\(moveCount)"
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
