//
//  RadialManager.swift
//  VectraPro
//
//  Services radials 0–359 from the radar center. Each enabled radial is drawn
//  as a green dashed line out to 250 NM. Enabled radials will come from the API
//  later; for now a default set is on.
//

import CoreLocation
import GeoNavKit
import UIKit

final class RadialManager {

    /// 20, 50, 90, 150 and their opposites.
    static let defaultRadials: Set<Int> = {
        let base = [20, 50, 90, 150]
        return Set(base + base.map { ($0 + 180) % 360 })
    }()

    private(set) var enabled: Set<Int>

    private let lengthNM = 350.0
    private let nauticalMile = 1852.0
    private let dashMeters = 3000.0
    private let gapMeters = 2000.0
    private let color = UIColor.green.withAlphaComponent(0.7)
    private let width: CGFloat = 0.8

    init(enabled: Set<Int> = RadialManager.defaultRadials) {
        self.enabled = enabled
    }

    // MARK: - Servicing any radial 0–359

    func isEnabled(_ degree: Int) -> Bool { enabled.contains(normalize(degree)) }
    func enable(_ degree: Int) { enabled.insert(normalize(degree)) }
    func disable(_ degree: Int) { enabled.remove(normalize(degree)) }
    func setEnabled(_ degrees: Set<Int>) { enabled = Set(degrees.map(normalize)) }

    private func normalize(_ degree: Int) -> Int { ((degree % 360) + 360) % 360 }

    // MARK: - Geometry

    /// Dashed lines from `center` out to 250 NM for every enabled radial.
    func lines(center: CLLocationCoordinate2D) -> [MapLine] {
        enabled.sorted().flatMap { radial(degree: Double($0), center: center) }
    }

    private func radial(degree: Double, center: CLLocationCoordinate2D) -> [MapLine] {
        let total = lengthNM * nauticalMile
        var lines: [MapLine] = []
        var distance = 0.0
        while distance < total {
            let segmentEnd = min(distance + dashMeters, total)
            let start = Geo.offset(from: center, distanceMeters: distance, bearingDegrees: degree)
            let end = Geo.offset(from: center, distanceMeters: segmentEnd, bearingDegrees: degree)
            lines.append(MapLine(coordinates: [start, end], color: color, width: width))
            distance += dashMeters + gapMeters
        }
        return lines
    }
}
