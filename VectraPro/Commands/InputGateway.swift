//
//  InputGateway.swift
//  VectraPro
//
//  The choke point every simulation input passes through: stamp, record, dispatch.
//
//  ── Five invariants, and how each is held ──────────────────────────────────
//
//  **One authoritative execution path.** The gateway does not execute anything. `CommandController.perform`
//  remains the only place a phraseology code becomes simulator behaviour; the gateway stamps and records
//  around it. There is no second route to the simulation, because there is no route here at all.
//
//  **Recording observes, never alters.** `submit` returns a receipt describing what was stamped, and
//  nothing in the command path branches on it. `SessionRecorder.record` returns nothing for the same
//  reason: a caller that could branch on a write result would be a caller whose behaviour depends on
//  recording.
//
//  **Recording disabled has no behavioural impact.** With no recorder attached the gateway increments a
//  counter and returns. It cannot refuse, delay, or reorder an input, and it never fails — see
//  `stamp(_:)`, which has no failure path at all.
//
//  **Deterministic and side-effect free.** The only state is an integer counter, advanced by exactly one
//  per input. The tick comes from `SimulationClock` via the view model. Nothing here reads a wall clock,
//  speaks, logs at runtime, or touches the network — the audit timestamp is stamped by `SessionRecorder`,
//  which is the recording layer, so this file stays inside the scan that bans real time in the command
//  path. That was not the first arrangement: the gateway stamped it, and `DeterministicTimeTests` caught
//  it, which is the guard doing its job on its author.
//
//  **The simulation never depends on whether recording is enabled.** Nothing in the simulation asks. The
//  recorder is an optional the gateway holds; the simulation holds the gateway and calls it the same way
//  either way.
//
//  ── One earlier decision reversed ──────────────────────────────────────────
//  The design doc said an input that could not be recorded must not execute, so a recording would always
//  explain its session. That is the wrong trade for a training product, and it contradicts the invariant
//  above: a trainee mid-exercise should not have instructions refused because a disk filled up. A write
//  failure now degrades the recording and the exercise continues. `SessionRecorder.isDegraded` is what
//  keeps that honest — an assessment that degraded cannot be sealed, so it cannot pass for a complete one.
//

import Foundation
import ATCReplayKit
import ATCSimKit

/// An input the simulation can act on, in the form worth recording.
///
/// Deliberately not `[AircraftCommand]`: those are derived, and a fix to the derivation should reach old
/// recordings rather than being frozen into them.
struct SimulationInput: Equatable {

    /// The phraseology `abbreviationCode`. The key everything downstream acts on.
    let code: String

    /// The aircraft addressed, as resolved at the time. Empty when the instruction named none and it went
    /// to the selected aircraft — recorded as resolved rather than as spoken, because resolution depends on
    /// who was on frequency then, which a replay cannot reconstruct and should not have to guess.
    let callsign: String

    /// Slot values as text, keyed by template slot name.
    let slots: [String: String]

    let source: EventSource
}

/// What the gateway did with an input.
///
/// Returned for diagnostics and tests. **Nothing in the command path branches on it** — that is what keeps
/// recording from altering behaviour.
struct InputReceipt: Equatable {
    let position: EventPosition
    let wasRecorded: Bool
}

@MainActor
final class InputGateway {

    /// Where recorded events go. Nil when nothing is recording.
    ///
    /// Settable rather than injected once, because a session starts and ends inside the life of one view
    /// model — and a fork replaces one recorder with another without the gateway being rebuilt.
    var recorder: SessionRecorder?

    /// Simulated time. A closure rather than a reference to the view model, so the gateway cannot reach
    /// into the simulation for anything else.
    private let currentTick: () -> Int

    /// The next ordinal. Monotonic, one owner, one actor — which is what makes it gap-free and race-free,
    /// and what makes `EventID` unique, since ids are derived from `(session, ordinal)`.
    private var nextOrdinal: UInt32 = 1

    /// Inputs and annotations stamped since this gateway was created. For the recording review; not used
    /// for anything the simulation reads.
    private(set) var stampedCount = 0

    init(currentTick: @escaping () -> Int) {
        self.currentTick = currentTick
    }

    nonisolated deinit { }

    // MARK: - Resuming

    /// Continues the ordinal sequence from an existing log.
    ///
    /// **Required after a crash.** Event ids are derived from `(session, ordinal)`, so a counter that
    /// restarted at 1 would mint ids that already exist — silently pointing two events, and any annotation
    /// on them, at the same name. `EventStore` refuses a non-increasing append, so getting this wrong fails
    /// loudly rather than quietly; it is still the caller's job to get it right.
    func resume(after position: EventPosition?) {
        guard let position else { return }
        nextOrdinal = max(nextOrdinal, position.ordinal + 1)
    }

    // MARK: - Stamp → Record → Dispatch

    /// Stamps an input and records it. Does **not** dispatch — the caller does that, through the one
    /// execution path.
    ///
    /// Cannot fail and cannot refuse. The caller proceeds identically whatever happens here, which is the
    /// invariant that lets a recorded exercise and an unrecorded one be the same exercise.
    @discardableResult
    func submit(_ input: SimulationInput) -> InputReceipt {
        let position = stamp()
        guard let recorder else {
            return InputReceipt(position: position, wasRecorded: false)
        }
        recorder.record(ATCEvent.commandIssued(code: input.code,
                                              callsign: input.callsign,
                                              slots: input.slots,
                                              at: position,
                                              source: input.source))
        return InputReceipt(position: position, wasRecorded: true)
    }

    /// Records something that happened but is not an input — a transcript, a readback, a refusal, a score.
    ///
    /// Recorded, never dispatched. This is what keeps the record complete without letting presentation into
    /// the simulation: a readback is a thing the trainee heard, and it drives nothing.
    ///
    /// Takes a closure because the position is assigned here and the event needs it: the gateway owns the
    /// ordinal, and an event built before it was stamped would have to be rebuilt. The closure is called with
    /// the stamped position and returns the event, which keeps every annotation going through one of
    /// `ATCEvent`'s fact-named constructors rather than through a payload this file would have to name.
    @discardableResult
    func annotate(_ event: (EventPosition) -> Event) -> InputReceipt {
        let position = stamp()
        guard let recorder else {
            return InputReceipt(position: position, wasRecorded: false)
        }
        recorder.record(event(position))
        return InputReceipt(position: position, wasRecorded: true)
    }

    // MARK: - Private

    /// Assigns the next position.
    ///
    /// The ordinal advances even when nothing is recording, so a session that starts recording partway
    /// through does not reuse ordinals — and so the counter behaves identically either way, which is one
    /// fewer difference between a recorded run and an unrecorded one.
    ///
    /// `wallClock` is stamped on the event, never read here. Simulated time is `currentTick()`.
    private func stamp() -> EventPosition {
        let position = EventPosition(tick: currentTick(), ordinal: nextOrdinal)
        nextOrdinal += 1
        stampedCount += 1
        return position
    }
}
