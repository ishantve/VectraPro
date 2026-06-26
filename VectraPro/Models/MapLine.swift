//
//  MapLine.swift
//  VectraPro
//
//  SDK-agnostic description of a styled polyline. Renderers produce these; the
//  map view turns them into native overlays.
//

import CoreLocation
import UIKit

struct MapLine {
    let coordinates: [CLLocationCoordinate2D]
    let color: UIColor
    let width: CGFloat
}
