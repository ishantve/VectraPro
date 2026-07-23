//
//  HoldingRacetrackTests.swift
//  VectraProTests
//
//  Holding-pattern geometry: derivation from speed, total length, sampling,
//  outline, and nearest-progress re-anchoring.
//

import Testing
import CoreLocation
@testable import VectraPro

@MainActor
struct HoldingRacetrackTests {

    private func track(speed: Double = 220, course: Double = 90) -> HoldingRacetrack {
        HoldingRacetrack(fix: Fixtures.center, inboundCourse: course, speedKnots: speed)
    }

    @Test func derivesPositiveRadiusAndLegFromSpeed() {
        let t = track(speed: 220)
        #expect(t.radiusM > 0)
        #expect(t.legM > 0)
        // 1-minute leg = ground speed (m/s) × 60.
        let vmps = 220 * 1852.0 / 3600
        #expect(abs(t.legM - vmps * 60) < 1.0)
    }

    @Test func totalLengthIsTwoLegsPlusTwoSemicircles() {
        let t = track()
        #expect(abs(t.totalLength - (2 * t.legM + 2 * .pi * t.radiusM)) < 1e-6)
    }

    @Test func sampleAtZeroIsAtTheFixOnInboundCourse() {
        let t = track(course: 90)
        let s = t.sample(at: 0)
        #expect(Geo.distanceMeters(from: s.position, to: Fixtures.center) < 5.0)
        #expect(abs(s.heading - 90) < 1.0)          // entering the pattern on the inbound course
    }

    @Test func sampleHeadingsAlwaysNormalised() {
        let t = track()
        for k in 0...20 {
            let s = t.sample(at: t.totalLength * Double(k) / 20)
            #expect(s.heading >= 0 && s.heading < 360)
        }
    }

    @Test func outlineReturnsSegmentsPlusOnePoints() {
        #expect(track().outline(segments: 96).count == 97)
    }

    @Test func nearestProgressRecoversAKnownPoint() {
        let t = track()
        let target = t.sample(at: 0.3 * t.totalLength).position
        let f = t.nearestProgress(to: target, near: 0.3)
        #expect(abs(f - 0.3) < 0.05)
    }

    @Test func explicitInitIsDeterministic() {
        let a = HoldingRacetrack(fix: Fixtures.center, inboundCourse: 45, radiusM: 2000, legM: 6000)
        let b = HoldingRacetrack(fix: Fixtures.center, inboundCourse: 45, radiusM: 2000, legM: 6000)
        let pa = a.sample(at: 1234).position
        let pb = b.sample(at: 1234).position
        #expect(approxEqual(pa, pb))
    }
}
