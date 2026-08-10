//
//  DeferredReportCoordinator.swift
//  VectraPro
//
//  Holds the reports aircraft owe, and speaks them when they come due.
//
//  Some phraseology asks for a report rather than an action:
//
//      ATC   "Air India 123, report passing PAPA JULIET."
//      pilot "Wilco, Air India one two three."
//      …later, on passing the point…
//      pilot "Air India one two three, passing PAPA JULIET."
//
//  The template's readback already carries both halves — the parser splits them at
//  the "Later:" marker — and ATCSimKit decides when the condition is met. This is
//  the piece in between: it keeps the deferred phrase alongside the condition's id,
//  and speaks it when the tracker says the moment has arrived.
//
//  Split this way because the phrase and the condition belong to different layers.
//  The simulator holds conditions and never sees readback text, which is what keeps
//  presentation out of the domain model.
//

import Foundation
import ATCParserKit
import ATCSimKit

/// The tick-side half of deferred reports, named so `MapViewModel` can be given a
/// stand-in instead of the app's own — a real one speaks.
@MainActor
protocol DeferredReportAnnouncing {
    func advance(aircraft: [Aircraft], allCallsigns: Set<String>,
                 fixes: [Fix], runways: [Runway])
}

final class DeferredReportCoordinator: DeferredReportAnnouncing {

    static let shared = DeferredReportCoordinator()

    private var tracker = PendingReportTracker()
    /// Rendered phrase per pending report.
    private var phrases: [UUID: Phrase] = [:]

    private init() {}

    // MARK: - Registration

    /// Registers the deferred half of a command's readback, if it has one.
    ///
    /// `aircraftCallsign` must be the aircraft's own callsign ("AIC123"), not the
    /// spoken form the controller used ("air india one two three"). The tracker
    /// finds the aircraft by it every tick, so a spoken form matches nothing and
    /// the report is dropped as belonging to an aircraft that has left. The phrase
    /// itself still names the aircraft the way it was spoken, which is what a pilot
    /// would say.
    ///
    /// A phrase still missing values is not registered: speaking a placeholder
    /// aloud is worse than not reporting, and an unresolved slot means the payload
    /// asks the pilot to say something the instruction never gave them.
    /// Code 320 is exactly that case until the backend corrects it.
    func register(_ command: RecognizedCommand, aircraftCallsign: String?) {
        guard let deferred = command.readback.deferred,
              let callsign = aircraftCallsign,
              let condition = CommandMapping.reportCondition(code: command.code, slots: command)
        else { return }

        guard deferred.unresolvedSlots.isEmpty else {
            #if DEBUG
            print("[DeferredReport] \(command.code) not registered — "
                  + "readback needs \(deferred.unresolvedSlots)")
            #endif
            return
        }

        let report = PendingReport(id: UUID(), callsign: callsign, condition: condition)
        if let displaced = tracker.register(report) { phrases[displaced] = nil }
        phrases[report.id] = deferred
    }

    // MARK: - Ticking

    /// Called each simulation tick. Speaks any report that has just come due and
    /// forgets those belonging to aircraft that have left the scene.
    func advance(aircraft: [Aircraft], allCallsigns: Set<String>,
                 fixes: [Fix], runways: [Runway]) {
        for id in tracker.forget(callsignsOtherThan: allCallsigns) { phrases[id] = nil }

        for id in tracker.evaluate(aircraft: aircraft, fixes: fixes, runways: runways) {
            defer { phrases[id] = nil }
            guard let spoken = phrases[id]?.spoken else { continue }
            CommandFeedbackManager.shared.readback(spoken)
        }
    }

    /// Pending count — for tests and debugging.
    var pendingCount: Int { tracker.pending.count }

    func reset() {
        tracker = PendingReportTracker()
        phrases = [:]
    }
}
