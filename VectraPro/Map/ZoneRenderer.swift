//
//  ZoneRenderer.swift
//  VectraPro
//
//  Builds airspace zone shapes (Danger / Prohibited / Restricted) from the
//  exercise detail: a solid-colored border, a transparent same-color fill, and
//  an off-white name label at the center.
//

import CoreLocation
import UIKit

/// A zone ready to render: polygon coordinates, colors, name and center.
struct ZoneShape {
    let coordinates: [CLLocationCoordinate2D]
    let strokeColor: UIColor
    let fillColor: UIColor
    let name: String
    let center: CLLocationCoordinate2D
}

enum ZoneRenderer {

    private static let maroon = UIColor(red: 0.5, green: 0.0, blue: 0.0, alpha: 0.9)
    private static let offWhite = UIColor(white: 0.93, alpha: 1.0)

    static func shapes(zones: [ExerciseDetail.Zone]) -> [ZoneShape] {
        var result: [ZoneShape] = []
        for zone in zones {
            guard zone.isActive == true, let colliders = zone.colliders else { continue }

            let coords = colliders.compactMap { c -> CLLocationCoordinate2D? in
                guard let lat = c.latitude, let lon = c.longitude else { return nil }
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
            guard coords.count >= 3 else { continue }

            let base = color(for: zone)
            result.append(ZoneShape(
                coordinates: coords,
                strokeColor: base,
                fillColor: base.withAlphaComponent(0.18),
                name: zone.zoneName ?? "",
                center: centroid(coords)
            ))
        }
        return result
    }

    /// Off-white, all-caps zone name rendered as an image (for a center marker).
    static func labelImage(_ name: String) -> UIImage {
        let text = name.uppercased() as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: offWhite
        ]
        let size = text.size(withAttributes: attrs)
        let canvas = CGSize(width: ceil(size.width) + 2, height: ceil(size.height) + 2)
        return UIGraphicsImageRenderer(size: canvas).image { _ in
            text.draw(at: CGPoint(x: 1, y: 1), withAttributes: attrs)
        }
    }

    private static func centroid(_ coords: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
        let count = Double(coords.count)
        let lat = coords.reduce(0.0) { $0 + $1.latitude } / count
        let lon = coords.reduce(0.0) { $0 + $1.longitude } / count
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private static func color(for zone: ExerciseDetail.Zone) -> UIColor {
        if let named = zone.color, let c = namedColor(named) { return c }
        switch zone.zoneType?.lowercased() {
        case "danger":     return UIColor.systemRed.withAlphaComponent(0.85)
        case "prohibited": return maroon
        case "restricted": return UIColor.systemOrange.withAlphaComponent(0.85)
        default:           return UIColor.systemYellow.withAlphaComponent(0.85)
        }
    }

    private static func namedColor(_ name: String) -> UIColor? {
        switch name.lowercased() {
        case "maroon": return maroon
        case "orange": return UIColor.systemOrange.withAlphaComponent(0.85)
        case "red":    return UIColor.systemRed.withAlphaComponent(0.85)
        case "yellow": return UIColor.systemYellow.withAlphaComponent(0.85)
        default:       return nil
        }
    }
}
