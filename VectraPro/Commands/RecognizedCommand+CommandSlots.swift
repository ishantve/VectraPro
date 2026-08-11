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

    /// Every slot the transmission filled, in template order.
    ///
    /// Template order, not sorted: this is the order the controller said them in, and a recording should
    /// read the way the instruction was given. Repeated placeholders — a block altitude names `LEVEL`
    /// twice — appear once, since a caller asks for occurrences by index.
    public nonisolated var slotNames: [String] {
        var seen = Set<String>()
        return slots.compactMap { seen.insert($0.name).inserted ? $0.name : nil }
    }

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


// MARK: - Filling a reply from aircraft state

extension Phrase {

    /// A copy with the simulator's values put into the slots the transcript could not
    /// fill — the aircraft's actual level or squawk, in a reply that has to contradict
    /// what was asked.
    ///
    /// Rendering uses each slot's own kind, so a level is still read digit by digit
    /// and a code four digits at a time, exactly as the affirmative reply would be.
    func filling(_ values: [String: CommandMapping.ConfirmedValue]) -> Phrase {
        guard !values.isEmpty else { return self }

        let spoken = segments.reduce(into: [String: String]()) { result, segment in
            guard case .slot(let name, let kind, nil) = segment,
                  let value = values[name] else { return }
            switch value {
            case .integer(let number):
                result[name] = SlotValue.integer(number).spoken(as: kind)
            case .text(let text):
                // Parsed for the slot's kind rather than spoken verbatim: a squawk of
                // "2000" has to come out as four digits, not as a number.
                switch SlotValue.parse([text], as: kind) {
                case .ok(let parsed), .outOfRange(let parsed):
                    result[name] = parsed.spoken(as: kind)
                case .unparsed:
                    result[name] = text
                }
            }
        }
        guard !spoken.isEmpty else { return self }

        return Phrase(
            segments: segments.map { segment in
                guard case .slot(let name, let kind, nil) = segment,
                      let filled = spoken[name] else { return segment }
                return .slot(name: name, kind: kind, spoken: filled)
            },
            unresolvedSlots: unresolvedSlots.filter { spoken[$0] == nil })
    }
}
