//
//  Geo.swift
//  GeoNavKit
//
//  Great-circle geographic helpers: bearing, distance, and offset. Pure maths
//  over CLLocationCoordinate2D — no app dependencies.
//

import CoreLocation

public enum Geo {

    /// Initial bearing in degrees (0–360) from one coordinate to another.
    public static func bearing(from: CLLocationCoordinate2D,
                               to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi

        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Great-circle distance in meters between two coordinates.
    public static func distanceMeters(from: CLLocationCoordinate2D,
                                      to: CLLocationCoordinate2D) -> Double {
        let a = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let b = CLLocation(latitude: to.latitude, longitude: to.longitude)
        return a.distance(from: b)
    }

    /// Destination coordinate reached by travelling `distanceMeters` from
    /// `from` along `bearingDegrees` (clockwise from north).
    public static func offset(from: CLLocationCoordinate2D,
                              distanceMeters: Double,
                              bearingDegrees: Double) -> CLLocationCoordinate2D {
        let earthRadius = 6_371_000.0
        let angular = distanceMeters / earthRadius
        let bearing = bearingDegrees * .pi / 180

        let lat1 = from.latitude * .pi / 180
        let lon1 = from.longitude * .pi / 180

        let lat2 = asin(sin(lat1) * cos(angular)
                        + cos(lat1) * sin(angular) * cos(bearing))
        let lon2 = lon1 + atan2(sin(bearing) * sin(angular) * cos(lat1),
                                cos(angular) - sin(lat1) * sin(lat2))

        return CLLocationCoordinate2D(
            latitude: lat2 * 180 / .pi,
            longitude: lon2 * 180 / .pi
        )
    }
}
