//
//  ReplayEventDescriptor.swift
//  VectraPro
//
//  Turns a recorded event into one user-facing line for the replay timeline.
//
//  This is the ATC interpretation layer, and it lives here — in the app, on top of the ATC adapter — on
//  purpose. ReplayCore routes opaque payloads and cannot read them; only an adapter can, via
//  `ATCEvent.payload(of:)`. So every ATC-specific phrasing decision is made here, never inside ReplayCore,
//  and the timeline UI receives finished strings rather than payloads to interpret.
//
//  Nothing here exposes a code, an enum case, a slot key spelled as JSON, or a serialized payload. A code the
//  deployment does not describe degrades to a safe generic line plus its values, never the raw code.
//

import Foundation
import ATCParserKit
import ATCReplayKit

struct ReplayEventDescriptor {

    /// Resolves a phraseology `code` to a human category label (e.g. "Altitude", "Vectoring"), or nil when the
    /// deployment's vocabulary does not describe it. Injected so the descriptor is testable without the app's
    /// template store, and so the ATC vocabulary stays the single source of the label.
    var label: (_ code: String) -> String?

    /// The app-wired descriptor: labels come from the loaded phraseology templates (the same vocabulary the
    /// recognizer uses), matched by `abbreviationCode`.
    @MainActor
    static let shared = ReplayEventDescriptor { code in
        CommandTemplateStore.shared.templates?.templates.first { $0.code == code }?.category
    }

    /// A user-facing line for a recorded event, or **nil** when the event should not appear in the timeline —
    /// a payload from another adapter this build cannot read, or a playback-control marker (pause / resume /
    /// speed change / seek) that is an artifact of watching a replay rather than something that happened in the
    /// session.
    func describe(_ event: Event) -> String? {
        guard let payload = ATCEvent.payload(of: event) else { return nil }

        switch payload {
        case .commandIssued(let code, let callsign, let slots):
            // Known code → its category ("Altitude clearance"); unknown → a safe generic ("a clearance"),
            // never the raw code. No leading article on the category, so "Altitude"/"Vectoring" both read right.
            let what = label(code).map { "\($0) clearance" } ?? "a clearance"
            return "Controller issued \(what) to \(callsignText(callsign))" + valuesSuffix(slots)

        case .commandRejected(_, let callsign, let reason):
            let who = callsign.map { " to \(callsignText($0))" } ?? ""
            return "Instruction refused\(who) — \(reason)"

        case .transcriptReceived(_, let normalized):
            return "Transmission: \(normalized)"

        case .readbackSpoken(let callsign, let spoken):
            return "\(callsignText(callsign)) read back: \(spoken)"

        case .weatherChanged(let windDegrees, let windKnots, let visibilityMetres, let qnh):
            return weatherText(windDegrees: windDegrees, windKnots: windKnots,
                               visibilityMetres: visibilityMetres, qnh: qnh)

        case .scoreEvaluated(let value, _):
            return "Score evaluated: \(value)"

        case .timelineAction(let action):
            switch action {
            case .replayStarted:  return "Session started"
            case .replayStopped:  return "Session ended"
            // Playback-control artifacts — not part of what happened in the session.
            case .paused, .resumed, .speedChanged, .seeked:
                return nil
            }
        }
    }

    // MARK: - Helpers

    private func callsignText(_ callsign: String) -> String {
        callsign.isEmpty ? "the selected aircraft" : callsign
    }

    /// Slot values as "key value" pairs, sorted for determinism, so a reader sees the numbers without the
    /// timeline having to know which slots a given instruction carries.
    private func valuesSuffix(_ slots: [String: String]) -> String {
        guard !slots.isEmpty else { return "" }
        let parts = slots.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
        return " (" + parts.joined(separator: ", ") + ")"
    }

    private func weatherText(windDegrees: Int?, windKnots: Int?, visibilityMetres: Int?, qnh: Int?) -> String {
        var parts: [String] = []
        if let d = windDegrees, let k = windKnots { parts.append("wind \(d)°/\(k) kt") }
        else if let d = windDegrees { parts.append("wind \(d)°") }
        else if let k = windKnots { parts.append("wind \(k) kt") }
        if let v = visibilityMetres { parts.append("visibility \(v) m") }
        if let q = qnh { parts.append("QNH \(q)") }
        return parts.isEmpty ? "Weather updated" : "Weather updated — " + parts.joined(separator: ", ")
    }
}
