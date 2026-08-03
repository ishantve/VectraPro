//
//  CommandController.swift
//  VectraPro
//
//  Receives raw voice transcripts and routes what they contain.
//
//  Flow:
//    raw transcript
//      → CommandRecognizer            every instruction it holds, in spoken order
//      → group by callsign            a transmission may address several aircraft
//      → code → [AircraftCommand]     via ATCSimKit's mapping
//      → apply + speak the readback   one reply per aircraft
//
//  Three things this does that the previous version could not:
//
//  • Several instructions survive. The old parser kept one command per category,
//    so "descend FL200 then descend FL180" quietly lost the second.
//  • Several aircraft are told apart. The old parser extracted one callsign and
//    applied everything to it — a second aircraft's instruction went to the first,
//    with no error at all.
//  • Nothing is dropped in silence. Speech no template accounts for, phraseology
//    disabled for this deployment, values outside limits, and codes the simulator
//    has not implemented are each reported differently.
//
//  The legacy parser is still here and takes over when the vocabulary cannot be
//  loaded. Losing command input entirely because a JSON payload is missing would be
//  a worse failure than running the older, narrower parser.
//

import Foundation
import ATCParserKit
import ATCSimKit

final class CommandController {

    private weak var mapViewModel: MapViewModel?
    private let store: CommandTemplateStore

    /// Everything this controller says out loud, behind the side-effect boundary.
    ///
    /// Injected rather than reached for. It used to call `CommandFeedbackManager.shared` from ten places,
    /// which made every one of them a side effect replay could not suppress — see `SideEffects.swift`.
    private let feedback: CommandFeedback

    /// Where a deferred report is registered.
    ///
    /// **Not** a side effect: the reports a pilot owes are simulation state, restored with everything else
    /// and advanced by the step loop. Only the *announcement* is a side effect, and that goes through
    /// `feedback` when the tick comes due. Injected so this controller reaches for nothing global.
    private let reports: DeferredReportAnnouncing

    init(mapViewModel: MapViewModel,
         store: CommandTemplateStore = .shared,
         feedback: CommandFeedback? = nil,
         reports: DeferredReportAnnouncing? = nil) {
        self.mapViewModel = mapViewModel
        self.store = store
        self.feedback = feedback ?? mapViewModel.sideEffects
        self.reports = reports ?? mapViewModel.deferredReports
    }

    // MARK: - Main entry point

    func process(_ transcript: String) {
        guard let recognizer = store.recognizer else {
            // Everything downstream is keyed on the vocabulary, so there is nothing
            // sensible to do without it. Saying so beats accepting commands and
            // handling them differently from every other part of the app.
            feedback.commandError("Unable, phraseology unavailable")
            return
        }

        let result = recognizer.recognize(transcript)
        guard !result.commands.isEmpty else {
            report(unrecognized: result.unrecognized)
            return
        }

        for group in result.groupedByCallsign() {
            route(group.commands, callsign: group.callsign)
        }

        // Speech that matched nothing is worth saying out loud only when some of
        // the transmission *did* land — otherwise it duplicates the failure above.
        report(partiallyUnrecognized: result.unrecognized)
    }

    // MARK: - Routing one aircraft's instructions

    private func route(_ commands: [RecognizedCommand], callsign: String?) {
        // Resolved once. Both the apply path and the report tracker need the
        // aircraft's own callsign; the spoken form only belongs in the readback.
        let target = callsign.flatMap { mapViewModel?.resolveRadarCallsign(from: $0) }
        var effects: [AircraftCommand] = []
        var spoken: [RecognizedCommand] = []

        for command in commands {
            switch command.outcome {
            case .invalidValue(let slot, let value):
                // The controller said something illegal — say so, and drop it.
                feedback.commandError(
                    "Unable, \(readable(slot)) \(readable(value)) is not valid")
                continue

            case .disabled:
                // Recognised but switched off here: answer it, do not act on it.
                spoken.append(command)
                continue

            case .ok:
                // Every point the command names is checked before the pilot agrees
                // to it. Accepting "report passing XYZ" or "level change at XYZ" for
                // a point that does not exist means the instruction can never be
                // carried out, and nothing would ever explain the silence.
                if case .rejected(let reason) = namedPointRejection(for: command) {
                    feedback.commandError(reason)
                    continue
                }

                // A question about an aircraft nobody found cannot be answered.
                // Falling through would speak the affirmative branch — telling the
                // controller a level is being maintained without having checked.
                if CommandMapping.answeredFromAircraft.contains(command.code),
                   aircraft(for: target) == nil {
                    feedback.aircraftNotFound()
                    continue
                }
                switch CommandMapping.map(code: command.code, slots: command) {
                case .commands(let mapped):
                    effects.append(contentsOf: mapped)
                    spoken.append(command)
                case .communicationOnly:
                    // No effect by design — a report, a standby, an acknowledgement.
                    spoken.append(command)
                case .unmapped:
                    // Recognised phraseology the simulator has not implemented.
                    // Reported rather than ignored, so a gap in the mapping table
                    // cannot pass for a command that worked.
                    feedback.commandError(
                        "Unable, \(command.category) instruction not implemented")
                }
            }
        }

        guard !spoken.isEmpty else { return }

        // "Report passing PJ" is answered now and reported later; register the
        // deferred half so it fires when the aircraft actually gets there.
        for command in spoken {
            reports.register(command, aircraftCallsign: target)
        }

        let readback = ReadbackComposer.compose(spoken.map { reply(to: $0, target: target) },
                                                callsign: callsign)

        guard !effects.isEmpty else {
            // Nothing to apply: answer directly rather than going through the
            // apply path, which would report "aircraft not found" for a plain
            // acknowledgement.
            if let readback {
                feedback.readback(readback)
            } else {
                // A reply that cannot be completed. "What are your intentions" asks
                // for something the simulator has no model of, and going quiet is
                // indistinguishable from the command having worked.
                reportUnanswerable(spoken)
            }
            return
        }

        apply(effects, callsign: callsign, target: target, readback: readback)
    }

    private func apply(_ effects: [AircraftCommand],
                       callsign: String?,
                       target: String?,
                       readback: String?) {
        guard let mapViewModel else { return }

        if let target {
            mapViewModel.applyToCallsign(target, commands: effects, readback: readback)
        } else if callsign != nil {
            // A callsign was spoken but no aircraft answers to it — never fall back
            // to the selected aircraft here, or an instruction meant for one
            // aircraft lands on another.
            feedback.aircraftNotFound()
        } else {
            mapViewModel.apply(effects, readback: readback)
        }
    }

    /// The aircraft a reply would be about, if one was found.
    private func aircraft(for target: String?) -> Aircraft? {
        guard let mapViewModel, let target else { return nil }
        return mapViewModel.aircraft(callsign: target)
    }

    /// The phrase to answer a command with.
    ///
    /// Usually its primary readback. A confirmation question — "confirm flight level
    /// two six zero" — has a second reply behind "If not:", and which one is true
    /// depends on the aircraft. Answering with the affirmative regardless would have
    /// the simulator agree to whatever it was asked: an aircraft at FL280 replying
    /// "maintaining two six zero".
    private func reply(to command: RecognizedCommand, target: String?) -> Phrase {
        let primary = command.readback.primary
        guard let mapViewModel, let aircraft = aircraft(for: target) else { return primary }
        let context = mapViewModel.validationContext

        // A question the aircraft answers about itself: heading, level, radial. The
        // request carries no such value, so without this the phrase stays incomplete
        // and is never spoken.
        if let values = CommandMapping.reportedValues(code: command.code,
                                                     aircraft: aircraft,
                                                     context: context) {
            return primary.filling(values)
        }

        guard let alternate = command.readback.alternate,
              let outcome = CommandMapping.confirm(code: command.code,
                                                   slots: command,
                                                   aircraft: aircraft,
                                                   context: context)
        else { return primary }

        switch outcome {
        case .affirm:
            return primary
        case .negative(let actual):
            return alternate.filling(actual)
        }
    }

    /// Whether every point the command names exists in the scene.
    ///
    /// Reads the fix-shaped slots rather than the command's effect, so it covers
    /// phraseology that names a point without changing anything — a report, or a
    /// level change coordinated "at" a point — as well as a hold or a direct routing.
    private func namedPointRejection(for command: RecognizedCommand) -> CommandValidator.Result {
        guard let mapViewModel else { return .ok }
        let named = command.slots.compactMap { slot -> String? in
            guard slot.kind == .fix, case .fix(let name)? = slot.value else { return nil }
            return name
        }
        guard !named.isEmpty else { return .ok }
        return CommandValidator.validate(fixNames: named,
                                         context: mapViewModel.validationContext)
    }

    /// Says so when phraseology was understood but cannot be answered.
    private func reportUnanswerable(_ commands: [RecognizedCommand]) {
        let missing = commands
            .filter { $0.readback.isRequired }
            .flatMap { $0.readback.primary.unresolvedSlots }
        guard !missing.isEmpty else { return }
        feedback.commandError(
            "Unable, \(missing.map { $0.lowercased() }.joined(separator: " and ")) not available")
    }

    // MARK: - Reporting what was not understood

    private func report(unrecognized fragments: [String]) {
        guard !fragments.isEmpty else {
            feedback.commandError("Command not recognized")
            return
        }
        feedback.commandError(
            "Say again — did not understand \(fragments.joined(separator: ", "))")
    }

    private func report(partiallyUnrecognized fragments: [String]) {
        guard !fragments.isEmpty else { return }
        #if DEBUG
        print("[CommandController] unrecognised fragments: \(fragments)")
        #endif
    }

    private func readable(_ slot: String) -> String {
        slot.lowercased() == "three digits" ? "heading" : slot.lowercased()
    }

    private func readable(_ value: SlotValue) -> String {
        switch value {
        case .integer(let value):      return String(value)
        case .runway(let designator):  return designator
        case .fix(let code):           return code
        case .frequency(let text):     return text
        case .text(let text):          return text
        }
    }

    /// Released classes need this. The target compiles with
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so a class's compiler-generated
    /// deinit is an isolated one, and the runtime hops an isolated deinit onto the
    /// main executor — which aborts the process on this toolchain (Swift 6.2.4).
    /// Singletons hide it by never being released; anything created per screen or
    /// per view is released for real. Declaring the deinit `nonisolated` says what is
    /// true — tearing this down needs no actor — and skips the hop.
    /// `IsolatedDeinitScanTests` is what catches a class that forgets it.
    nonisolated deinit { }
}
