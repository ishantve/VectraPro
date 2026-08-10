//
//  PendingReportTracker.swift
//  ATCSimKit
//
//  "Report passing PAPA JULIET" — the pilot says WILCO now, and reports later,
//  when it happens. This decides when "later" is.
//
//  ── Closest approach, inside a radius ───────────────────────────────────────
//  Two rules together, because either alone is wrong.
//
//  A fixed radius alone — the way a hold captures an aircraft — misses a genuine
//  pass slightly off track, and then the report never fires and nobody notices.
//
//  Closest approach alone is worse in a quieter way: every turn produces a local
//  minimum in distance, so an aircraft that happened to swing toward a point twenty
//  miles away and then away again "passed" it. That is not passing, and reporting it
//  is a wrong readback rather than a missing one.
//
//  So a pass is a turnaround in distance that happens *within* `passingRadius` of
//  the point — overhead, not merely nearby. An aircraft vectored off and then flown
//  back on a parallel track goes abeam the point without ever passing it, and must
//  not report; only actually crossing over it counts.
//
//  Closeness is measured along the path flown, not at the sampled positions. With a
//  radius as tight as a mile, an aircraft can cross overhead *between* two ticks and
//  leave no sample inside the radius at all — so the rule would depend on the tick
//  rate rather than on where the aircraft went. The segment between successive
//  positions is measured instead.
//
//  A distance report needs no radius: it names its own range, so crossing that range
//  is the whole condition.
//
//  ── What this holds ─────────────────────────────────────────────────────────
//  Conditions only, never the words. The phrase is rendered from the template that
//  was spoken and belongs to the layer that speaks it; keeping readback text out of
//  the simulator is what stops presentation leaking into the domain. Reports are
//  handed back by id and the caller looks up what to say.
//

import CoreLocation
import Foundation
import GeoNavKit

// MARK: - Condition

public enum ReportCondition: Equatable, Sendable {
    /// Passing a named point — detected by closest approach.
    case passingFix(String)
    /// Reaching a range from a named point, crossed in either direction.
    case distanceFromFix(nauticalMiles: Double, fix: String)
    /// Established on the localizer the aircraft has been cleared to intercept.
    case establishedOnLocalizer
}

// MARK: - Report

public struct PendingReport: Equatable, Sendable {
    public let id: UUID
    /// Keyed by callsign rather than aircraft id: it is what the controller
    /// addressed, and it survives an aircraft moving between the radar and the
    /// hangar. Reports for a callsign no longer in the scene are dropped.
    public let callsign: String
    public let condition: ReportCondition

    /// Distance at the previous evaluation — how a crossing is recognised.
    var lastDistanceM: Double?
    /// Position at the previous evaluation, so the path between ticks can be measured
    /// rather than only the ticks themselves.
    var lastPosition: CLLocationCoordinate2D?
    /// Closest the aircraft has actually come, counting the path flown between ticks.
    var closestSeenM: Double
    /// Set once the aircraft has been seen closing on the point. Without it, an
    /// aircraft that starts out flying away would "pass" the fix immediately.
    var hasApproached: Bool

    public init(id: UUID, callsign: String, condition: ReportCondition) {
        self.id = id
        self.callsign = callsign
        self.condition = condition
        self.lastDistanceM = nil
        self.lastPosition = nil
        self.closestSeenM = .greatestFiniteMagnitude
        self.hasApproached = false
    }

    /// Compared on what identifies the report, not on how far along its tracking has
    /// got. Two reports for the same aircraft and condition are the same debt whether
    /// or not one has already seen the aircraft move.
    public static func == (lhs: PendingReport, rhs: PendingReport) -> Bool {
        lhs.id == rhs.id && lhs.callsign == rhs.callsign && lhs.condition == rhs.condition
    }
}

// MARK: - Tracker

public struct PendingReportTracker: Equatable, Sendable {

    /// How close an aircraft must come for a turnaround to count as passing a point.
    ///
    /// One mile: overhead within navigation tolerance, which is what a controller
    /// means by "report passing". Anything looser reports an aircraft that merely went
    /// past at a distance — a track parallel to the point, three miles abeam, is not a
    /// pass however neatly the distance turns around.
    ///
    /// It is also the radius `HoldingController` already captures a hold with, so the
    /// simulator keeps one idea of being at a fix rather than two.
    public static let defaultPassingRadiusNM = 1.0

    public let passingRadiusM: Double
    private var reports: [PendingReport] = []

    public init(passingRadiusNM: Double = PendingReportTracker.defaultPassingRadiusNM) {
        self.passingRadiusM = passingRadiusNM * Distance.metersPerNauticalMile
    }

    public var pending: [PendingReport] { reports }

    // MARK: Registration

    /// Adds a report, replacing any the same aircraft already owes for the same
    /// condition — asking twice does not mean the pilot reports twice.
    ///
    /// Returns the id of any report that was displaced, so the caller can forget
    /// its phrase.
    @discardableResult
    public mutating func register(_ report: PendingReport) -> UUID? {
        let displaced = reports.first {
            $0.callsign.caseInsensitiveCompare(report.callsign) == .orderedSame
                && $0.condition == report.condition
        }
        reports.removeAll { $0.id == displaced?.id }
        reports.append(report)
        return displaced?.id
    }

    // MARK: Evaluation

    /// Advances every pending report and returns those whose condition has just
    /// been met. Fired reports are removed.
    public mutating func evaluate(aircraft: [Aircraft],
                                  fixes: [Fix],
                                  runways: [Runway]) -> [UUID] {
        var fired: [UUID] = []

        for index in reports.indices.reversed() {
            guard let plane = aircraft.first(where: {
                $0.callsign.caseInsensitiveCompare(reports[index].callsign) == .orderedSame
            }) else { continue }

            if isMet(&reports[index], for: plane, fixes: fixes, runways: runways) {
                fired.append(reports[index].id)
                reports.remove(at: index)
            }
        }
        return fired.reversed()
    }

    /// Drops reports for callsigns no longer in the scene — an aircraft that has
    /// landed or been removed owes nothing.
    ///
    /// Returns the forgotten ids so the caller can release their phrases.
    @discardableResult
    public mutating func forget(callsignsOtherThan present: Set<String>) -> [UUID] {
        let upper = Set(present.map { $0.uppercased() })
        let gone = reports.filter { !upper.contains($0.callsign.uppercased()) }
        reports.removeAll { report in gone.contains { $0.id == report.id } }
        return gone.map(\.id)
    }

    // MARK: - Conditions

    private func isMet(_ report: inout PendingReport,
                       for aircraft: Aircraft,
                       fixes: [Fix],
                       runways: [Runway]) -> Bool {
        switch report.condition {
        case .passingFix(let name):
            guard let fix = FixLookup.position(named: name, in: fixes) else { return false }
            let distance = Geo.distanceMeters(from: aircraft.position, to: fix)

            // How close the aircraft came since the last tick, including the ground
            // it covered in between — not just where it happened to be sampled.
            if let from = report.lastPosition {
                report.closestSeenM = min(report.closestSeenM,
                                          Self.distanceM(from: fix,
                                                         toSegmentFrom: from,
                                                         to: aircraft.position))
            }
            report.closestSeenM = min(report.closestSeenM, distance)

            defer {
                report.lastDistanceM = distance
                report.lastPosition = aircraft.position
            }
            guard let previous = report.lastDistanceM else { return false }
            if distance < previous { report.hasApproached = true }
            // Closing, then opening, and it actually got near the point. The radius is
            // what stops a turn twenty miles away, or a parallel track three miles
            // abeam, counting as a pass.
            return report.hasApproached
                && distance > previous
                && report.closestSeenM <= passingRadiusM

        case .distanceFromFix(let nauticalMiles, let name):
            guard let distance = distanceM(from: aircraft, toFixNamed: name, in: fixes) else {
                return false
            }
            defer { report.lastDistanceM = distance }
            guard let previous = report.lastDistanceM else { return false }
            let target = nauticalMiles * Distance.metersPerNauticalMile
            return (previous > target && distance <= target)
                || (previous < target && distance >= target)

        case .establishedOnLocalizer:
            // The template names no runway; the one the aircraft was cleared to
            // intercept is the one it reports being established on.
            guard let runway = aircraft.interceptRunway else { return false }
            return LocalizerGuidanceService.isInCone(aircraft: aircraft,
                                                     runway: runway,
                                                     runways: runways)
        }
    }

    private func distanceM(from aircraft: Aircraft,
                           toFixNamed name: String,
                           in fixes: [Fix]) -> Double? {
        guard let position = FixLookup.position(named: name, in: fixes) else { return nil }
        return Geo.distanceMeters(from: aircraft.position, to: position)
    }

    /// Closest the straight track from `from` to `to` comes to `point`.
    ///
    /// A flat local projection: over the few miles a single tick covers, the error is
    /// far below the tolerance being tested against, and it avoids depending on how
    /// finely the simulation happens to sample.
    static func distanceM(from point: CLLocationCoordinate2D,
                          toSegmentFrom from: CLLocationCoordinate2D,
                          to end: CLLocationCoordinate2D) -> Double {
        let metersPerDegreeLat = 111_320.0
        let metersPerDegreeLon = metersPerDegreeLat * cos(point.latitude * .pi / 180)

        func vector(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> (x: Double, y: Double) {
            ((b.longitude - a.longitude) * metersPerDegreeLon,
             (b.latitude - a.latitude) * metersPerDegreeLat)
        }

        let segment = vector(from, end)
        let toPoint = vector(from, point)
        let lengthSquared = segment.x * segment.x + segment.y * segment.y
        guard lengthSquared > 0 else {
            return Geo.distanceMeters(from: from, to: point)
        }

        // Where along the segment the point projects, clamped to its ends.
        let t = max(0, min(1, (toPoint.x * segment.x + toPoint.y * segment.y) / lengthSquared))
        let closest = (x: segment.x * t, y: segment.y * t)
        let dx = toPoint.x - closest.x
        let dy = toPoint.y - closest.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
