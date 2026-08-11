//
//  KeyboardCommandCatalog.swift
//  VectraPro
//
//  What each keypad key means, in the only vocabulary that matters: a backend
//  phraseology code.
//
//  The keypad used to build `AircraftCommand`s itself, one function per key. That
//  made it a third independent copy of the vocabulary — after the parser and the
//  feedback layer — and it showed: a key and the spoken phrase for the same
//  instruction could disagree, and the keypad produced no ICAO readback at all.
//
//  Naming a code instead means the keypad joins the same pipeline speech uses.
//  A key is not parsed — the controller *chose* the phrase — so there is no
//  transcript, only a code and the values typed on the keypad. Everything after
//  that point is shared: `CommandMapping` decides the effect, the template decides
//  the readback.
//
//  The payload carries a `keyboardShortCut` field per template, currently blank
//  throughout. When it is populated this table becomes redundant — the keypad can
//  be built from the vocabulary instead of matched against it.
//

import Foundation

/// A keypad key bound to a phraseology code.
struct KeyboardCommand {
    /// Backend `abbreviationCode`.
    let code: String
    /// Placeholder the typed value fills, nil for keys that take no value.
    let slot: String?
    /// How many values the key collects (a block altitude needs two).
    let valueCount: Int
    /// Values are entered as flight levels but templates hold `[LEVEL]` too, so no
    /// conversion happens here — `CommandMapping` owns that.
    let prompt: String

    init(code: String, slot: String? = nil, valueCount: Int = 1, prompt: String) {
        self.code = code
        self.slot = slot
        self.valueCount = valueCount
        self.prompt = prompt
    }
}

enum KeyboardCommandCatalog {

    /// Key title as drawn on the keypad → the phraseology it stands for.
    ///
    /// Keys absent from this table are the ones that need input the keypad cannot
    /// collect — a fix name for `DIR` and `HLD`, a runway for `ILOC` and `C/T` —
    /// or phraseology the simulator has no behaviour for yet (`GO ARD`). They keep
    /// their existing no-op handlers rather than being wired to something wrong.
    /// Every bound key.
    ///
    /// Sorted, because a test iterates it and an unsorted dictionary would report a different key first
    /// on each run — which makes a failure harder to reproduce than it needs to be.
    static var allKeys: [String] { byKey.keys.sorted() }

    static let byKey: [String: KeyboardCommand] = [
        // Speed
        "↑SPD*":   .init(code: "359", slot: "NUMBER", prompt: "Increase speed to xxx knots"),
        "↓SPD*":   .init(code: "361", slot: "NUMBER", prompt: "Reduce speed to xxx knots"),
        "SPD*":    .init(code: "344", slot: "NUMBER", prompt: "Maintain xxx knots"),
        "SPD≥*":   .init(code: "346", slot: "NUMBER", prompt: "Maintain xxx knots or greater"),
        "SPD≤*":   .init(code: "348", slot: "NUMBER", prompt: "Maintain xxx knots or less"),

        // Altitude — the keypad enters flight levels, which is what [LEVEL] holds.
        "C/M*":    .init(code: "101", slot: "LEVEL", prompt: "Climb to FL xxx"),
        "D/M*":    .init(code: "158", slot: "LEVEL", prompt: "Descend to FL xxx"),
        "MBLK*-*": .init(code: "235", slot: "LEVEL", valueCount: 2,
                         prompt: "Maintain block FL xxx through FL xxx"),

        // Vectoring
        "TLH":     .init(code: "246", slot: "THREE DIGITS", prompt: "Turn left heading xxx"),
        "TRH":     .init(code: "247", slot: "THREE DIGITS", prompt: "Turn right heading xxx"),
        "T*DL":    .init(code: "250", slot: "NUMBER OF DEGREES", prompt: "Turn xxx degrees left"),
        "T*DR":    .init(code: "251", slot: "NUMBER OF DEGREES", prompt: "Turn xxx degrees right"),
        "FH":      .init(code: "245", slot: "THREE DIGITS", prompt: "Fly heading xxx"),
        "FPH":     .init(code: "243", slot: nil, valueCount: 0,
                         prompt: "Continue present heading"),
    ]

    static func command(for key: String) -> KeyboardCommand? { byKey[key] }
}
