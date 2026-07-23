//
//  MapGeometryTests.swift
//  VectraProTests
//
//  Pure geometry extracted from RadarMapController.
//

import Testing
import CoreLocation
@testable import VectraPro

@MainActor
struct TrailSamplerTests {

    /// A straight northbound track of `n` points spaced `stepNM` apart.
    private func straightHistory(n: Int, stepNM: Double) -> [CLLocationCoordinate2D] {
        var pts: [CLLocationCoordinate2D] = []
        var p = Fixtures.center
        for _ in 0..<n {
            pts.append(p)
            p = Fixtures.offsetNM(from: p, nm: stepNM, bearing: 0)
        }
        return pts
    }

    @Test func fixedSpacedReturnsRequestedCountEvenlySpaced() {
        let history = straightHistory(n: 25, stepNM: 0.3)   // ~7.2 NM of track
        let dots = TrailSampler.fixedSpaced(from: history, count: 6, spacingNM: 0.6)

        #expect(dots.count == 6)
        // On a straight line, adjacent dots should be ~0.6 NM apart.
        for i in 1..<dots.count {
            let gapNM = Geo.distanceMeters(from: dots[i - 1], to: dots[i]) / Distance.metersPerNauticalMile
            #expect(abs(gapNM - 0.6) < 0.1)
        }
    }

    @Test func fixedSpacedProjectsBackwardWhenHistoryShort() {
        // Only 2 points but 6 dots requested → the rest are projected backward.
        let history = straightHistory(n: 2, stepNM: 0.1)
        let dots = TrailSampler.fixedSpaced(from: history, count: 6, spacingNM: 0.6)
        #expect(dots.count == 6)
    }

    @Test func fixedSpacedNeedsAtLeastTwoPoints() {
        #expect(TrailSampler.fixedSpaced(from: [], count: 6, spacingNM: 0.6).isEmpty)
        #expect(TrailSampler.fixedSpaced(from: [Fixtures.center], count: 6, spacingNM: 0.6).isEmpty)
    }

    @Test func equalSpacedReturnsRequestedCount() {
        let history = straightHistory(n: 10, stepNM: 0.4)
        #expect(TrailSampler.equalSpaced(from: history, count: 6).count == 6)
    }
}

@MainActor
struct ColliderGeometryTests {

    @Test func circleHasStepsPointsAllAtRadius() {
        let center = Fixtures.center
        let radiusNM = 2.5
        let ring = ColliderGeometry.circle(center: center, radiusNM: radiusNM)   // default 36 steps

        #expect(ring.count == 36)
        for p in ring {
            let dNM = Geo.distanceMeters(from: center, to: p) / Distance.metersPerNauticalMile
            #expect(abs(dNM - radiusNM) < 0.05)
        }
    }

    @Test func diamondIsClosedWithFrontPointAhead() {
        let center = Fixtures.center
        let d = ColliderGeometry.diamond(center: center, forwardNM: 0.6, sideNM: 0.6, headingDeg: 45)

        #expect(d.count == 5)
        #expect(approxEqual(d.first!, d.last!))         // closed ring
        // First vertex is the "front", forwardNM ahead along the heading.
        let frontNM = Geo.distanceMeters(from: center, to: d[0]) / Distance.metersPerNauticalMile
        #expect(abs(frontNM - 0.6) < 0.05)
        let frontBrg = Geo.bearing(from: center, to: d[0])
        #expect(abs(frontBrg - 45) < 1.0)
    }

    @Test func noseRectIsClosedRectangle() {
        let center = Fixtures.center
        let r = ColliderGeometry.noseRect(center: center, forwardNM: 0.62, sideNM: 0.07, headingDeg: 0)
        #expect(r.count == 5)
        #expect(approxEqual(r.first!, r.last!))         // [fL, fR, bR, bL, fL]
    }
}
