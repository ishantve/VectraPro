//
//  ColliderGeometry.swift
//  GeoNavKit
//
//  Pure geographic shape geometry for colliders and range circles. Each
//  function returns a closed ring of coordinates. NM → metres uses 1 NM = 1852 m.
//

import CoreLocation

public enum ColliderGeometry {

    /// The 4 corners of a heading-aligned diamond (+ closing point):
    ///   front → headingDeg, right → +90°, back → +180°, left → +270°.
    public static func diamond(center: CLLocationCoordinate2D,
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

    /// The 4 corners of a heading-aligned rectangle as [fL, fR, bR, bL, fL].
    public static func noseRect(center: CLLocationCoordinate2D,
                                forwardNM: Double, sideNM: Double,
                                headingDeg: Double) -> [CLLocationCoordinate2D] {
        let front = Geo.offset(from: center, distanceMeters: forwardNM * 1852, bearingDegrees: headingDeg)
        let back  = Geo.offset(from: center, distanceMeters: forwardNM * 1852, bearingDegrees: headingDeg + 180)
        let fR = Geo.offset(from: front, distanceMeters: sideNM * 1852, bearingDegrees: headingDeg + 90)
        let fL = Geo.offset(from: front, distanceMeters: sideNM * 1852, bearingDegrees: headingDeg - 90)
        let bR = Geo.offset(from: back,  distanceMeters: sideNM * 1852, bearingDegrees: headingDeg + 90)
        let bL = Geo.offset(from: back,  distanceMeters: sideNM * 1852, bearingDegrees: headingDeg - 90)
        return [fL, fR, bR, bL, fL]
    }

    /// A geographic circle approximated as a polygon with `steps` segments.
    public static func circle(center: CLLocationCoordinate2D, radiusNM: Double,
                              steps: Int = 36) -> [CLLocationCoordinate2D] {
        (0..<steps).map { i in
            Geo.offset(from: center,
                       distanceMeters: radiusNM * 1852.0,
                       bearingDegrees: Double(i) * 360.0 / Double(steps))
        }
    }
}
