//
//  RecognizedCommand+CommandSlots.swift
//  VectraPro
//
//  The one place the parser's world meets the simulator's.
//
//  ATCSimKit reads a recognised command's values through its own `CommandSlots`
//  protocol so it needs no knowledge of templates, slots or the parser at all —
//  it asks for an integer named "THREE DIGITS" and gets one. That protocol is
//  satisfied here, in the app, because the app is the only layer that legitimately
//  knows about both sides.
//
//  Values arriving as `.outOfRange` are not handed over. A heading of 450 is
//  reported to the controller as a rejection; passing it down as if it were a
//  heading would turn the aircraft somewhere arbitrary.
//

import ATCParserKit
import ATCSimKit

extension RecognizedCommand: @retroactive CommandSlots {

    public nonisolated func integer(_ name: String, occurrence: Int) -> Int? {
        guard case .integer(let value)? = value(name, occurrence) else { return nil }
        return value
    }

    public nonisolated func text(_ name: String, occurrence: Int) -> String? {
        switch value(name, occurrence) {
        case .text(let text):        return text
        case .fix(let code):         return code
        case .runway(let designator): return designator
        case .frequency(let text):   return text
        case .integer(let value):    return String(value)
        case nil:                    return nil
        }
    }

    /// The nth value carried under `name`. Position matters: a block clearance
    /// names two levels under one placeholder, so asking by name alone would give
    /// the same one twice.
    private nonisolated func value(_ name: String, _ occurrence: Int) -> SlotValue? {
        let matching = slots.filter { $0.name == name && $0.isValid }
        guard matching.indices.contains(occurrence) else { return nil }
        return matching[occurrence].value
    }
}
