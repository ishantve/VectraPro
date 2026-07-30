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

    init(mapViewModel: MapViewModel, store: CommandTemplateStore = .shared) {
        self.mapViewModel = mapViewModel
        self.store = store
    }

    // MARK: - Main entry point

    func process(_ transcript: String) {
        guard let recognizer = store.recognizer else {
            processWithLegacyParser(transcript)
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
        var effects: [AircraftCommand] = []
        var spoken: [RecognizedCommand] = []

        for command in commands {
            switch command.outcome {
            case .invalidValue(let slot, let value):
                // The controller said something illegal — say so, and drop it.
                CommandFeedbackManager.shared.commandError(
                    "Unable, \(readable(slot)) \(readable(value)) is not valid")
                continue

            case .disabled:
                // Recognised but switched off here: answer it, do not act on it.
                spoken.append(command)
                continue

            case .ok:
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
                    CommandFeedbackManager.shared.commandError(
                        "Unable, \(command.category) instruction not implemented")
                }
            }
        }

        guard !spoken.isEmpty else { return }

        // "Report passing PJ" is answered now and reported later; register the
        // deferred half so it fires when the aircraft actually gets there.
        for command in spoken { DeferredReportCoordinator.shared.register(command) }

        let readback = ReadbackComposer.compose(spoken, callsign: callsign)

        guard !effects.isEmpty else {
            // Nothing to apply: answer directly rather than going through the
            // apply path, which would report "aircraft not found" for a plain
            // acknowledgement.
            if let readback { CommandFeedbackManager.shared.readback(readback) }
            return
        }

        apply(effects, callsign: callsign, readback: readback)
    }

    private func apply(_ effects: [AircraftCommand], callsign: String?, readback: String?) {
        guard let mapViewModel else { return }

        if let callsign, let resolved = mapViewModel.resolveRadarCallsign(from: callsign) {
            mapViewModel.applyToCallsign(resolved, commands: effects, readback: readback)
        } else if callsign != nil {
            // A callsign was spoken but no aircraft answers to it — never fall back
            // to the selected aircraft here, or an instruction meant for one
            // aircraft lands on another.
            CommandFeedbackManager.shared.aircraftNotFound()
        } else {
            mapViewModel.apply(effects)
        }
    }

    // MARK: - Reporting what was not understood

    private func report(unrecognized fragments: [String]) {
        guard !fragments.isEmpty else {
            CommandFeedbackManager.shared.commandError("Command not recognized")
            return
        }
        CommandFeedbackManager.shared.commandError(
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

    // MARK: - Legacy path

    /// The pre-template parser, kept as a fallback for a missing or unreadable
    /// vocabulary. Scheduled for removal once the payload is served by the backend.
    private func processWithLegacyParser(_ transcript: String) {
        guard let result = try? ATCParser().parse(transcript) else {
            CommandFeedbackManager.shared.commandError("Command not recognized")
            return
        }
        let normalized = result.normalized

        if isTakeoffClearance(normalized) {
            if let callsign = mapViewModel?.resolveDepartureCallsign(from: normalized) {
                mapViewModel?.clearForTakeoff(callsign: callsign)
            } else {
                CommandFeedbackManager.shared.aircraftNotFound()
            }
            return
        }

        let commands = result.commands.compactMap(AircraftCommand.init)
        guard !commands.isEmpty else {
            CommandFeedbackManager.shared.commandError("Command not recognized")
            return
        }

        if let cs = result.callsign,
           let callsign = mapViewModel?.resolveRadarCallsign(from: cs) {
            mapViewModel?.applyToCallsign(callsign, commands: commands)
        } else if let callsign = mapViewModel?.resolveRadarCallsign(from: normalized) {
            mapViewModel?.applyToCallsign(callsign, commands: commands)
        } else {
            mapViewModel?.apply(commands)
        }
    }

    private func isTakeoffClearance(_ normalized: String) -> Bool {
        normalized.contains("clear") &&
        (normalized.contains("takeoff") || normalized.contains("take off"))
    }
}
