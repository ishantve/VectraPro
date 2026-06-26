//
//  RunwayRenderer.swift
//  VectraPro
//
//  Builds the runway centerline as a MapLine.
//

import UIKit

enum RunwayRenderer {

    static func lines(_ runway: Runway) -> [MapLine] {
        [
            MapLine(
                coordinates: [runway.endA.coordinate, runway.endB.coordinate],
                color: .white,
                width: 4
            ),
        ]
    }
}
