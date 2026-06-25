//
//  Approach.swift
//  VectraPro
//
//  Identifies one approach direction (a single runway end) that can be
//  enabled independently, e.g. "27".
//

import Foundation

enum RunwayEndSide: Hashable {
    case a
    case b
}

/// Stable identity for a runway end / approach direction.
struct ApproachID: Hashable {
    let runwayID: UUID
    let side: RunwayEndSide
}

struct Approach: Identifiable {
    let id: ApproachID
    let designator: String
}

extension Runway {

    /// The threshold aircraft cross when landing on this approach side.
    func threshold(_ side: RunwayEndSide) -> RunwayThreshold {
        side == .a ? endA : endB
    }

    /// The opposite threshold (used to derive the approach course).
    func otherThreshold(_ side: RunwayEndSide) -> RunwayThreshold {
        side == .a ? endB : endA
    }

    var approaches: [Approach] {
        [
            Approach(id: ApproachID(runwayID: id, side: .a), designator: endA.designator),
            Approach(id: ApproachID(runwayID: id, side: .b), designator: endB.designator),
        ]
    }
}
