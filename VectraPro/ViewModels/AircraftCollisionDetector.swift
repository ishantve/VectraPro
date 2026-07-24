//
//  AircraftCollisionDetector.swift
//  VectraPro
//
//  All collision detection: aircraft-aircraft, zone boundary, and fix colliders.
//  Owns all geometry math (flat-Earth projection, shape overlap tests).
//

import CoreLocation
import Foundation

// MARK: - Result types

/// Outcome of an aircraft-to-aircraft conflict check for one simulation tick.
struct AircraftConflictResult {
    var yellows:   Set<UUID>   // separation circles touching (< 5 NM, same altitude band)
    var reds:      Set<UUID>   // critical proximity (< 3 NM)
    var destroyed: Set<UUID>   // body/nose colliders overlap → both aircraft removed
}

/// Outcome of a zone conflict check for one simulation tick.
struct ZoneConflictResult {
    var warnings:  Set<UUID>   // collider ring touches zone boundary
    var destroyed: Set<UUID>   // aircraft body is inside zone → removed
}

// MARK: - Detector

final class AircraftCollisionDetector {

    static let shared = AircraftCollisionDetector()
    private init() {}

    private let fixColliderRadiusNM = 1.0    // HOLDING circle radius
    private let fixColliderSizeNM   = 1.0    // WAYPOINT triangle vertex distance

    // MARK: - Public: detection

    func detectConflicts(in aircraft: [Aircraft]) -> AircraftConflictResult {
        var yellows  = Set<UUID>()
        var reds     = Set<UUID>()
        var bodyHits = Set<UUID>()

        for i in 0..<aircraft.count {
            for j in (i + 1)..<aircraft.count {
                let a = aircraft[i], b = aircraft[j]

                // Vertically separated (≥ 1000 ft apart) → no conflict of ANY kind:
                // they can neither collide nor infringe separation, even if their
                // horizontal footprints overlap. Guard up front so this gates the
                // body/nose collision too, not just the proximity rings.
                guard abs(a.altitudeFeet - b.altitudeFeet) < 1000 else { continue }

                let aXY = (x: 0.0, y: 0.0)
                let bXY = flatXY(origin: a.position, target: b.position)
                let aH  = a.headingDegrees * .pi / 180
                let bH  = b.headingDegrees * .pi / 180

                let nA = (x: aXY.x + a.noseOffsetNM * 1852 * sin(aH),
                          y: aXY.y + a.noseOffsetNM * 1852 * cos(aH))
                let nB = (x: bXY.x + b.noseOffsetNM * 1852 * sin(bH),
                          y: bXY.y + b.noseOffsetNM * 1852 * cos(bH))

                let hit = diamondsOverlap(cx1: aXY.x, cy1: aXY.y, f1: a.bodyForwardNM * 1852, s1: a.bodySideNM * 1852, h1: aH,
                                          cx2: bXY.x, cy2: bXY.y, f2: b.bodyForwardNM * 1852, s2: b.bodySideNM * 1852, h2: bH)
                       || rectDiamondOverlap(rx: nA.x, ry: nA.y, rf: a.noseForwardNM * 1852, rs: a.noseSideNM * 1852, rh: aH,
                                             dx: bXY.x, dy: bXY.y, df: b.bodyForwardNM * 1852, ds: b.bodySideNM * 1852, dh: bH)
                       || rectDiamondOverlap(rx: nB.x, ry: nB.y, rf: b.noseForwardNM * 1852, rs: b.noseSideNM * 1852, rh: bH,
                                             dx: aXY.x, dy: aXY.y, df: a.bodyForwardNM * 1852, ds: a.bodySideNM * 1852, dh: aH)
                       || rectsOverlap(cx1: nA.x, cy1: nA.y, f1: a.noseForwardNM * 1852, s1: a.noseSideNM * 1852, h1: aH,
                                       cx2: nB.x, cy2: nB.y, f2: b.noseForwardNM * 1852, s2: b.noseSideNM * 1852, h2: bH)
                if hit {
                    bodyHits.insert(a.id); bodyHits.insert(b.id)
                    continue
                }

                let hDistNM = hypot(bXY.x, bXY.y) / 1852.0
                if hDistNM < (a.colliderRadiusNM + b.colliderRadiusNM) {
                    yellows.insert(a.id); yellows.insert(b.id)
                }
                if hDistNM < 3.0 {
                    reds.insert(a.id); reds.insert(b.id)
                }
            }
        }

        return AircraftConflictResult(yellows: yellows, reds: reds, destroyed: bodyHits)
    }

    func detectZoneConflicts(aircraft: [Aircraft], zoneShapes: [ZoneShape]) -> ZoneConflictResult {
        var warnings  = Set<UUID>()
        var destroyed = Set<UUID>()

        for ac in aircraft {
            // Destroy when ANY part of the aircraft collider (nose OR body side)
            // crosses a zone boundary — test every collider vertex.
            let colliderPoints = aircraftColliderPoints(ac)
            let hit = zoneShapes.contains { shape in
                colliderPoints.contains { polygonContains(shape.coordinates, point: $0) }
            }
            if hit {
                destroyed.insert(ac.id)
            } else {
                let thresholdM = ac.colliderRadiusNM * 1852.0
                let touchesBoundary = zoneShapes.contains { shape in
                    let coords = shape.coordinates
                    guard coords.count >= 2 else { return false }
                    for i in 0..<coords.count {
                        let a = coords[i], b = coords[(i + 1) % coords.count]
                        if distanceToSegmentMeters(point: ac.position, segA: a, segB: b) < thresholdM {
                            return true
                        }
                    }
                    return false
                }
                if touchesBoundary { warnings.insert(ac.id) }
            }
        }

        return ZoneConflictResult(warnings: warnings, destroyed: destroyed)
    }

    /// Geographic vertices of an aircraft's collider: the 4 body-diamond corners
    /// (front / right / back / left) plus the nose tip. Used for zone-boundary
    /// crossing so a side/nose touch — not just the centre — triggers a hit.
    private func aircraftColliderPoints(_ ac: Aircraft) -> [CLLocationCoordinate2D] {
        let h = ac.headingDegrees
        func p(_ nm: Double, _ bearing: Double) -> CLLocationCoordinate2D {
            Geo.offset(from: ac.position, distanceMeters: nm * 1852.0, bearingDegrees: bearing)
        }
        return [
            p(ac.bodyForwardNM, h),                       // front
            p(ac.bodySideNM,    h + 90),                  // right
            p(ac.bodyForwardNM, h + 180),                 // back
            p(ac.bodySideNM,    h + 270),                 // left
            p(ac.noseOffsetNM + ac.noseForwardNM, h),     // nose tip
        ]
    }

    func detectFixConflicts(aircraft: [Aircraft], fixes: [ExerciseDetail.Fix]) -> Set<UUID> {
        var conflicts = Set<UUID>()
        for ac in aircraft {
            for fix in fixes {
                guard let lat = fix.latitude, let lon = fix.longitude else { continue }
                let fixPos = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                if fix.type?.uppercased() == "HOLDING" {
                    if Geo.distanceMeters(from: ac.position, to: fixPos) < fixColliderRadiusNM * 1852 {
                        conflicts.insert(ac.id)
                    }
                } else {
                    if pointInFixTriangle(point: ac.position, center: fixPos,
                                         sizeM: fixColliderSizeNM * 1852) {
                        conflicts.insert(ac.id)
                    }
                }
            }
        }
        return conflicts
    }

    // MARK: - Private: flat-Earth projection

    /// Equirectangular approximation: lat/lon → (x East, y North) in metres.
    /// Error < 0.1% within 200 NM — acceptable for ATC radar collision math.
    private func flatXY(origin: CLLocationCoordinate2D,
                        target: CLLocationCoordinate2D) -> (x: Double, y: Double) {
        let R = 6_371_000.0
        let dLat = (target.latitude  - origin.latitude)  * .pi / 180
        let dLon = (target.longitude - origin.longitude) * .pi / 180
        let meanLat = (origin.latitude + target.latitude) / 2 * .pi / 180
        return (x: dLon * cos(meanLat) * R, y: dLat * R)
    }

    // MARK: - Private: diamond (body) collision

    private func pointInDiamond(px: Double, py: Double, cx: Double, cy: Double,
                                 forwardM: Double, sideM: Double, headingRad: Double) -> Bool {
        let dx = px - cx, dy = py - cy
        let fwd   = dx * sin(headingRad) + dy * cos(headingRad)
        let right = dx * cos(headingRad) - dy * sin(headingRad)
        return abs(fwd) / forwardM + abs(right) / sideM <= 1.0
    }

    private func diamondVerts(cx: Double, cy: Double, forwardM: Double, sideM: Double,
                               headingRad: Double) -> [(Double, Double)] {
        let sinH = sin(headingRad), cosH = cos(headingRad)
        return [
            (cx + forwardM * sinH,  cy + forwardM * cosH),
            (cx + sideM   * cosH,   cy - sideM   * sinH),
            (cx - forwardM * sinH,  cy - forwardM * cosH),
            (cx - sideM   * cosH,   cy + sideM   * sinH),
        ]
    }

    private func diamondsOverlap(cx1: Double, cy1: Double, f1: Double, s1: Double, h1: Double,
                                  cx2: Double, cy2: Double, f2: Double, s2: Double, h2: Double) -> Bool {
        if pointInDiamond(px: cx2, py: cy2, cx: cx1, cy: cy1, forwardM: f1, sideM: s1, headingRad: h1) { return true }
        if pointInDiamond(px: cx1, py: cy1, cx: cx2, cy: cy2, forwardM: f2, sideM: s2, headingRad: h2) { return true }
        for (vx, vy) in diamondVerts(cx: cx1, cy: cy1, forwardM: f1, sideM: s1, headingRad: h1) {
            if pointInDiamond(px: vx, py: vy, cx: cx2, cy: cy2, forwardM: f2, sideM: s2, headingRad: h2) { return true }
        }
        for (vx, vy) in diamondVerts(cx: cx2, cy: cy2, forwardM: f2, sideM: s2, headingRad: h2) {
            if pointInDiamond(px: vx, py: vy, cx: cx1, cy: cy1, forwardM: f1, sideM: s1, headingRad: h1) { return true }
        }
        return false
    }

    // MARK: - Private: rectangle (nose) collision

    private func pointInRect(px: Double, py: Double, cx: Double, cy: Double,
                              forwardM: Double, sideM: Double, headingRad: Double) -> Bool {
        let dx = px - cx, dy = py - cy
        let fwd   = dx * sin(headingRad) + dy * cos(headingRad)
        let right = dx * cos(headingRad) - dy * sin(headingRad)
        return abs(fwd) <= forwardM && abs(right) <= sideM
    }

    private func rectVerts(cx: Double, cy: Double, forwardM: Double, sideM: Double,
                            headingRad: Double) -> [(Double, Double)] {
        let sinH = sin(headingRad), cosH = cos(headingRad)
        return [
            (cx + forwardM * sinH + sideM * cosH, cy + forwardM * cosH - sideM * sinH),
            (cx + forwardM * sinH - sideM * cosH, cy + forwardM * cosH + sideM * sinH),
            (cx - forwardM * sinH - sideM * cosH, cy - forwardM * cosH + sideM * sinH),
            (cx - forwardM * sinH + sideM * cosH, cy - forwardM * cosH - sideM * sinH),
        ]
    }

    private func rectsOverlap(cx1: Double, cy1: Double, f1: Double, s1: Double, h1: Double,
                               cx2: Double, cy2: Double, f2: Double, s2: Double, h2: Double) -> Bool {
        if pointInRect(px: cx2, py: cy2, cx: cx1, cy: cy1, forwardM: f1, sideM: s1, headingRad: h1) { return true }
        if pointInRect(px: cx1, py: cy1, cx: cx2, cy: cy2, forwardM: f2, sideM: s2, headingRad: h2) { return true }
        for (vx, vy) in rectVerts(cx: cx1, cy: cy1, forwardM: f1, sideM: s1, headingRad: h1) {
            if pointInRect(px: vx, py: vy, cx: cx2, cy: cy2, forwardM: f2, sideM: s2, headingRad: h2) { return true }
        }
        for (vx, vy) in rectVerts(cx: cx2, cy: cy2, forwardM: f2, sideM: s2, headingRad: h2) {
            if pointInRect(px: vx, py: vy, cx: cx1, cy: cy1, forwardM: f1, sideM: s1, headingRad: h1) { return true }
        }
        return false
    }

    private func rectDiamondOverlap(rx: Double, ry: Double, rf: Double, rs: Double, rh: Double,
                                     dx: Double, dy: Double, df: Double, ds: Double, dh: Double) -> Bool {
        if pointInDiamond(px: rx, py: ry, cx: dx, cy: dy, forwardM: df, sideM: ds, headingRad: dh) { return true }
        if pointInRect(px: dx, py: dy, cx: rx, cy: ry, forwardM: rf, sideM: rs, headingRad: rh)    { return true }
        for (vx, vy) in rectVerts(cx: rx, cy: ry, forwardM: rf, sideM: rs, headingRad: rh) {
            if pointInDiamond(px: vx, py: vy, cx: dx, cy: dy, forwardM: df, sideM: ds, headingRad: dh) { return true }
        }
        for (vx, vy) in diamondVerts(cx: dx, cy: dy, forwardM: df, sideM: ds, headingRad: dh) {
            if pointInRect(px: vx, py: vy, cx: rx, cy: ry, forwardM: rf, sideM: rs, headingRad: rh) { return true }
        }
        return false
    }

    // MARK: - Private: fix / zone geometry

    private func pointInFixTriangle(point: CLLocationCoordinate2D,
                                     center: CLLocationCoordinate2D,
                                     sizeM: Double) -> Bool {
        let p  = flatXY(origin: center, target: point)
        let v0 = (x: 0.0,             y:  sizeM)
        let v1 = (x:  sizeM * 0.866,  y: -sizeM * 0.5)
        let v2 = (x: -sizeM * 0.866,  y: -sizeM * 0.5)
        func cross(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double),
                   _ c: (x: Double, y: Double)) -> Double {
            (a.x - c.x) * (b.y - c.y) - (b.x - c.x) * (a.y - c.y)
        }
        let d1 = cross(p, v0, v1), d2 = cross(p, v1, v2), d3 = cross(p, v2, v0)
        return !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0))
    }

    private func distanceToSegmentMeters(point: CLLocationCoordinate2D,
                                          segA: CLLocationCoordinate2D,
                                          segB: CLLocationCoordinate2D) -> Double {
        let p  = flatXY(origin: segA, target: point)
        let ab = flatXY(origin: segA, target: segB)
        let lenSq = ab.x * ab.x + ab.y * ab.y
        guard lenSq > 0 else { return hypot(p.x, p.y) }
        let t = max(0, min(1, (p.x * ab.x + p.y * ab.y) / lenSq))
        return hypot(p.x - ab.x * t, p.y - ab.y * t)
    }

    private func polygonContains(_ polygon: [CLLocationCoordinate2D],
                                  point: CLLocationCoordinate2D) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let xi = polygon[i].longitude, yi = polygon[i].latitude
            let xj = polygon[j].longitude, yj = polygon[j].latitude
            let crossesY = (yi > point.latitude) != (yj > point.latitude)
            let xIntersect = (xj - xi) * (point.latitude - yi) / (yj - yi) + xi
            if crossesY && point.longitude < xIntersect { inside = !inside }
            j = i
        }
        return inside
    }
}
