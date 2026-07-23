//
//  ColliderGeometry.swift
//  VectraPro
//
//  Pure geographic shape geometry for aircraft colliders and range circles,
//  extracted from RadarMapController. Each function returns a closed ring of
//  coordinates the controller draws as a polyline — no map/rendering state, so
//  the geometry is testable on its own. NM → metres uses 1 NM = 1852 m.
//

import CoreLocation

enum ColliderGeometry {

    /// The 4 geographic corners of a heading-aligned diamond (+ closing point):
    ///   front → bearing = headingDeg,       distance = forwardNM
    ///   right → bearing = headingDeg + 90°,  distance = sideNM
    ///   back  → bearing = headingDeg + 180°, distance = forwardNM
    ///   left  → bearing = headingDeg + 270°, distance = sideNM
    /// The first point is repeated at the end to close the polyline.
    static func diamond(center: CLLocationCoordinate2D,
                        forwardNM: Double, sideNM: Double,
                        headingDeg: Double) -> [CLLocationCoordinate2D] {
        let offsets: [(Double, Double)] = [
            (forwardNM * 1852, headingDeg),        // front
            (sideNM    * 1852, headingDeg + 90),   // right
            (forwardNM * 1852, headingDeg + 180),  // back
            (sideNM    * 1852, headingDeg + 270),  // left
        ]
        var pts = offsets.map { Geo.offset(from: center, distanceMeters: $0.0, bearingDegrees: $0.1) }
        pts.append(pts[0])   // close the shape
        return pts
    }

    /// The 4 geographic corners of a heading-aligned rectangle (+ closing point).
    ///
    /// Project the centre forward and backward by forwardNM to get the front-edge
    /// and back-edge midpoints, then offset each left and right by sideNM:
    ///   fR = front + sideNM at (heading + 90°)   fL = front + sideNM at (heading − 90°)
    ///   bR = back  + sideNM at (heading + 90°)   bL = back  + sideNM at (heading − 90°)
    /// Returned as [fL, fR, bR, bL, fL] so the polyline traces the rectangle.
    static func noseRect(center: CLLocationCoordinate2D,
                         forwardNM: Double, sideNM: Double,
                         headingDeg: Double) -> [CLLocationCoordinate2D] {
        let front = Geo.offset(from: center, distanceMeters: forwardNM * 1852, bearingDegrees: headingDeg)
        let back  = Geo.offset(from: center, distanceMeters: forwardNM * 1852, bearingDegrees: headingDeg + 180)
        let fR = Geo.offset(from: front, distanceMeters: sideNM * 1852, bearingDegrees: headingDeg + 90)
        let fL = Geo.offset(from: front, distanceMeters: sideNM * 1852, bearingDegrees: headingDeg - 90)
        let bR = Geo.offset(from: back,  distanceMeters: sideNM * 1852, bearingDegrees: headingDeg + 90)
        let bL = Geo.offset(from: back,  distanceMeters: sideNM * 1852, bearingDegrees: headingDeg - 90)
        return [fL, fR, bR, bL, fL]   // closed rectangle
    }

    /// Approximates a geographic circle as a polygon with `steps` equal-angle
    /// segments. 36 steps = 10° per segment — smooth at radar zoom and cheap.
    static func circle(center: CLLocationCoordinate2D, radiusNM: Double,
                       steps: Int = 36) -> [CLLocationCoordinate2D] {
        (0..<steps).map { i in
            Geo.offset(from: center,
                       distanceMeters: radiusNM * 1852.0,
                       bearingDegrees: Double(i) * 360.0 / Double(steps))
        }
    }
}
