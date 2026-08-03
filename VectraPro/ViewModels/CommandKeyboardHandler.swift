//
//  CommandKeyboardHandler.swift
//  VectraPro
//
//  Logic for the radar command keypad, kept separate from its view
//  (`CommandKeyboard`).
//
//  A key names a phraseology code (see `KeyboardCommandCatalog`); everything after
//  that is the pipeline speech already uses — `CommandMapping` for the effect, the
//  template for the readback. So the keypad and the microphone cannot drift apart,
//  and the keypad now produces proper ICAO readbacks, which it never did before.
//
//  Some commands need a numeric value (the "*" in the key, e.g. ↑SPD*). For those,
//  `requiresValue` is true and the view collects a number via the numeric keypad,
//  then calls `perform(_:value:)`.
//

import Foundation
import ATCParserKit
import ATCSimKit

@MainActor
final class CommandKeyboardHandler {

    static let shared = CommandKeyboardHandler()

    /// The view-model commands are applied to — injected (defaults to the shared
    /// instance) rather than reached into globally, so the dependency is explicit.
    private let radar: MapViewModel
    private let store: CommandTemplateStore
    private let renderer = ReadbackRenderer()

    /// Everything this handler says out loud, behind the side-effect boundary — see `SideEffects.swift`.
    /// Taken from the view model so the keypad and the microphone share one gate; two gates could be in
    /// two modes, and a seek would silence one of them.
    private var feedback: CommandFeedback { radar.sideEffects }

    /// Not private: a test needs a handler pointed at its own view model rather than the shared one, and
    /// so will a second live session. The defaults keep every existing call site unchanged.
    /// The app target defaults to `MainActor` isolation, which makes an implicit deinit isolated, and
    /// releasing one off the main actor aborts the process. Invisible while this was only ever the shared
    /// singleton — never released, so the deinit never ran. The third class in this project to need this;
    /// `IsolatedDeinitScanTests` now covers it.
    nonisolated deinit { }

    init(radar: MapViewModel? = nil, store: CommandTemplateStore? = nil) {
        self.radar = radar ?? .shared
        self.store = store ?? .shared
    }

    // MARK: - Key metadata

    /// True if the command needs a number entered before it applies.
    func requiresValue(_ command: String) -> Bool {
        (KeyboardCommandCatalog.command(for: command)?.valueCount ?? 0) > 0
    }

    /// How many numbers the command needs (block altitude needs two).
    func valueCount(for command: String) -> Int {
        max(1, KeyboardCommandCatalog.command(for: command)?.valueCount ?? 1)
    }

    /// Full command sentence shown on the keypad; the keypad replaces "xxx"
    /// with the value being typed.
    func prompt(for command: String) -> String {
        KeyboardCommandCatalog.command(for: command)?.prompt ?? command
    }

    // MARK: - Applying

    /// Apply a single-value command with the number entered on the keypad.
    func perform(_ command: String, value: Int) {
        apply(command, values: [value])
    }

    /// Apply a two-value (block altitude) command.
    func perform(_ command: String, low: Int, high: Int) {
        apply(command, values: [low, high])
    }

    /// Routes a tapped key (its title) to its function.
    func perform(_ command: String) {
        if KeyboardCommandCatalog.command(for: command) != nil {
            apply(command, values: [])
            return
        }
        // Keys that need input the keypad cannot collect, or phraseology with no
        // behaviour yet. Left as they were rather than wired to something wrong.
        switch command {
        case "ILOC Rwy*": ilocRunway()
        case "C/T Rwy*":  clearedToRunway()
        case "GO ARD":    goAround()
        case "HLD":       hold()
        case "H/O":       handOff()
        case "DIR":       direct()
        default:
            #if DEBUG
            print("CommandKeyboard: unhandled command \(command)")
            #endif
        }
    }

    /// The one path every keypad command takes: code + values → effect + readback.
    private func apply(_ key: String, values: [Int]) {
        guard let binding = KeyboardCommandCatalog.command(for: key) else { return }
        guard store.templates != nil else {
            // The reply comes from the template, so without the vocabulary a key would
            // act on an aircraft and then say nothing about it.
            feedback.commandError("Unable, phraseology unavailable")
            return
        }

        let slots = StaticCommandSlots(
            integers: binding.slot.map { [$0: values] } ?? [:])

        switch CommandMapping.map(code: binding.code, slots: slots) {
        case .commands(let effects):
            radar.apply(effects, readback: readback(for: binding, values: values))
        case .communicationOnly:
            if let spoken = readback(for: binding, values: values) {
                feedback.readback(spoken)
            }
        case .unmapped:
            // A key bound to a code the simulator has no behaviour for. Reported
            // rather than ignored — a silent key is indistinguishable from a
            // working one.
            feedback.commandError(
                "Unable, \(binding.prompt.lowercased()) not implemented")
        }
    }

    /// ICAO readback for the chosen template, spoken to the selected aircraft.
    /// Nil when the vocabulary is unavailable, in which case the legacy English
    /// built from the command enum is used instead.
    private func readback(for binding: KeyboardCommand, values: [Int]) -> String? {
        guard let template = store.templates?.template(id: binding.code),
              let slot = binding.slot else {
            return store.templates?.template(id: binding.code).flatMap {
                renderer.render($0, values: [:], callsign: radar.selectedCallsign).text
            }
        }
        let rendered = renderer.render(
            template,
            values: [slot: values.map { SlotValue.integer($0) }],
            callsign: radar.selectedCallsign)
        return rendered.text
    }

    // MARK: - Keys awaiting more input or more behaviour

    func ilocRunway()        { /* needs a runway; see code 454 */ }
    func clearedToRunway()   { /* needs a runway; see code 436 */ }
    func goAround()          { /* code 327 — no behaviour yet */ }
    func hold()              { /* needs a fix; see code 453 */ }
    func handOff()           { /* needs a unit and frequency; see code 448 */ }
    func direct()            { /* needs a fix; see code 445 */ }
}
