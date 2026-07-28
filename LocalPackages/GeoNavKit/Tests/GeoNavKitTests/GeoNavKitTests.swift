//
//  GeoNavKitTests.swift
//  GeoNavKit
//

import XCTest
import CoreLocation
@testable import GeoNavKit

final class GeoNavKitTests: XCTestCase {

    private let delhi = CLLocationCoordinate2D(latitude: 28.5665, longitude: 77.1031)

    func testBearingDueEast() {
        let east = Geo.offset(from: delhi, distanceMeters: 5000, bearingDegrees: 90)
        XCTAssertEqual(Geo.bearing(from: delhi, to: east), 90, accuracy: 0.5)
    }

    func testDistanceRoundTrip() {
        // offset() is spherical, distanceMeters() is ellipsoidal (CLLocation), so
        // a round-trip carries a small (~0.1%) model mismatch — allow for it.
        let p = Geo.offset(from: delhi, distanceMeters: 1852, bearingDegrees: 45)
        XCTAssertEqual(Geo.distanceMeters(from: delhi, to: p), 1852, accuracy: 5.0)
    }

    func testNauticalMileConversion() {
        XCTAssertEqual(Distance.metersPerNauticalMile, 1852)
        XCTAssertEqual(2.0.nauticalMilesToMeters, 3704, accuracy: 0.001)
    }

    func testCircleHasStepsPointsAtRadius() {
        let ring = ColliderGeometry.circle(center: delhi, radiusNM: 2.5)
        XCTAssertEqual(ring.count, 36)
        for p in ring {
            let dNM = Geo.distanceMeters(from: delhi, to: p) / Distance.metersPerNauticalMile
            XCTAssertEqual(dNM, 2.5, accuracy: 0.05)
        }
    }

    func testDiamondIsClosed() {
        let d = ColliderGeometry.diamond(center: delhi, forwardNM: 0.6, sideNM: 0.6, headingDeg: 45)
        XCTAssertEqual(d.count, 5)
        XCTAssertEqual(d.first!.latitude, d.last!.latitude, accuracy: 1e-9)
    }

    func testFixedSpacedReturnsCount() {
        var pts: [CLLocationCoordinate2D] = []
        var p = delhi
        for _ in 0..<25 { pts.append(p); p = Geo.offset(from: p, distanceMeters: 0.3 * 1852, bearingDegrees: 0) }
        XCTAssertEqual(TrailSampler.fixedSpaced(from: pts, count: 6, spacingNM: 0.6).count, 6)
    }
}
