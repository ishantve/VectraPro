//
//  PendingReportTracker.swift
//  ATCSimKit
//
//  "Report passing PAPA JULIET" — the pilot says WILCO now, and reports later,
//  when it happens. This decides when "later" is.
//
//  ── Why closest approach, not proximity ──────────────────────────────────────
//  The obvious test is "within N miles of the fix", the way a hold captures an
//  aircraft. It is wrong here: an aircraft can pass a point comfortably outside
//  any fixed radius, and then the report never fires and nobody notices — the same
//  class of silent failure this rewrite exists to remove. So a pass is detected by
//  the distance turning around: it was closing, now it is opening.
//
//  A distance report is the same measurement read differently — the moment the
//  aircraft crosses the requested range, in either direction.
//
//  ── What this holds ─────────────────────────────────────────────────────────
//  Conditions only, never the words. The phrase is rendered from the template that
//  was spoken and belongs to the layer that speaks it; keeping readback text out of
//  the simulator is what stops presentation leaking into the domain. Reports are
//  handed back by id and the caller looks up what to say.
//

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
    /// Set once the aircraft has been seen closing on the point. Without it, an
    /// aircraft that starts out flying away would "pass" the fix immediately.
    var hasApproached: Bool

    public init(id: UUID, callsign: String, condition: ReportCondition) {
        self.id = id
        self.callsign = callsign
        self.condition = condition
        self.lastDistanceM = nil
        self.hasApproached = false
    }
}

// MARK: - Tracker

public struct PendingReportTracker: Equatable, Sendable {

    private var reports: [PendingReport] = []

    public init() {}

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
            guard let distance = distanceM(from: aircraft, toFixNamed: name, in: fixes) else {
                return false
            }
            defer { report.lastDistanceM = distance }
            guard let previous = report.lastDistanceM else { return false }
            if distance < previous { report.hasApproached = true }
            // Closing, then opening — the aircraft has just gone by.
            return report.hasApproached && distance > previous

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
}
