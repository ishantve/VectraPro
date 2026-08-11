//
//  CommandMapping.swift
//  ATCSimKit
//
//  Turns a recognised phraseology code into what it does to an aircraft.
//
//  This is the one seam between the lexical world and the simulator. The parser
//  knows the words and nothing about aircraft; the simulator knows aircraft and
//  nothing about templates. Neither can own the translation, so it lives here —
//  with `AircraftCommand`, the type it produces — and is keyed on the backend's
//  `abbreviationCode`.
//
//  ── Why a protocol instead of the parser's own types ───────────────────────────
//  Reading values through `CommandSlots` keeps this package free of any dependency
//  on the parser. The simulator does not need to know that templates or slots
//  exist; it needs an integer for "THREE DIGITS". A caller supplies a twenty-line
//  conformance, and this file stays testable with a dictionary.
//
//  ── Why three outcomes ────────────────────────────────────────────────────────
//  Most phraseology has no effect on an aircraft at all — a report, a standby, a
//  frequency change. That is not a failure, so it cannot share an answer with "no
//  such code". Today's app treats a nil mapping as a parser bug; here the two are
//  told apart, and only `unmapped` is worth an alert.
//

import Foundation
import GeoNavKit

// MARK: - Slot access

/// Read access to the values a recognised command carried.
///
/// `occurrence` exists because a placeholder can repeat — a block clearance names
/// two levels under one name — so position, not name alone, identifies a value.
public protocol CommandSlots {
    func integer(_ name: String, occurrence: Int) -> Int?
    func text(_ name: String, occurrence: Int) -> String?

    /// Every slot this instruction filled, in template order.
    ///
    /// Added so an instruction's values can be written down without knowing which template it came from.
    /// The mapping table asks for slots by name because it knows what it wants; recording does not, and
    /// cannot, so it needs to be able to ask what is there.
    var slotNames: [String] { get }
}

public extension CommandSlots {
    func integer(_ name: String) -> Int? { integer(name, occurrence: 0) }
    func text(_ name: String) -> String? { text(name, occurrence: 0) }
}

/// Dictionary-backed slots, for tests and for callers assembling a command by
/// hand — the command keyboard picks a template rather than speaking one, so it
/// has values without ever going through the parser.
public struct StaticCommandSlots: CommandSlots {
    private let integers: [String: [Int]]
    private let texts: [String: [String]]

    public init(integers: [String: [Int]] = [:], texts: [String: [String]] = [:]) {
        self.integers = integers
        self.texts = texts
    }

    public func integer(_ name: String, occurrence: Int) -> Int? {
        integers[name].flatMap { $0.indices.contains(occurrence) ? $0[occurrence] : nil }
    }

    public func text(_ name: String, occurrence: Int) -> String? {
        texts[name].flatMap { $0.indices.contains(occurrence) ? $0[occurrence] : nil }
    }

    /// Sorted, because these come from dictionaries and dictionary order is not stable in Swift — an
    /// unsorted answer would make a recording's slot order differ between two runs of the same input.
    public var slotNames: [String] {
        Array(Set(integers.keys).union(texts.keys)).sorted()
    }
}

// MARK: - Mapping

public enum CommandMapping {

    public enum Result: Equatable {
        /// What the instruction does. One code can produce several commands —
        /// "proceed direct, hold as published, maintain FL260" is three.
        case commands([AircraftCommand])
        /// Recognised phraseology that deliberately changes nothing: reports,
        /// acknowledgements, frequency changes. Answer it, do not act on it.
        case communicationOnly
        /// No entry for this code. Either the backend added phraseology the
        /// simulator has not implemented, or a code was renumbered. Worth
        /// reporting — silence here looks exactly like a working no-op.
        case unmapped
    }

    public static func map(code: String, slots: CommandSlots) -> Result {
        if let build = actionable[code] {
            let commands = build(slots)
            // A mapping that cannot assemble its command — a missing or
            // unparseable value — is not the same as one that has no effect.
            return commands.isEmpty ? .unmapped : .commands(commands)
        }
        return communicationOnly.contains(code) ? .communicationOnly : .unmapped
    }

    /// Codes with no effect on an aircraft.
    ///
    /// Listed explicitly rather than derived from the payload's category, because
    /// category does not predict this: "genphrase" holds both `DISREGARD`, which
    /// changes nothing, and `PROCEED DIRECT TO`, which re-routes the aircraft.
    public static let communicationOnly: Set<String> = [
        // reports
        "316", "317", "318", "319", "320",
        // identification
        "258", "264",
        // level check / confirmations
        "216", "430",
        // radar service, vectoring advisory
        "267", "449",
        // frequency change, QNH
        "431", "448",
        // 122/123 sit under "climb", but "REQUEST LEVEL CHANGE FROM [UNIT NAME]"
        // is coordination with another control unit, not an instruction to an
        // aircraft — another case of the category not predicting the behaviour.
        "122", "123",
        // ILS/GBAS/SBAS/MLS establishment reports and confirmations
        "405", "406", "407", "408", "409", "410", "411", "412",
        // mode C — no transponder mode in the aircraft model yet
        "371", "372", "437",
        // standby, roger, general phrases
        "432", "433", "434", "435", "442", "443", "444",
    ]

    /// Codes that change an aircraft, and how.
    ///
    /// One code is deliberately absent. 304 assigns a standard departure — a named
    /// route — and there is no route or procedure model to assign it to. Mapping it
    /// would mean inventing one for a single template, so it reports as `unmapped`
    /// and the controller is told the instruction is not implemented, which is true.
    /// `CommandMappingTests` prints whatever is unmapped, so this stays visible
    /// rather than becoming a silent gap.
    private static let actionable: [String: (CommandSlots) -> [AircraftCommand]] = [

        // MARK: Vertical — climb, descend, maintain
        //
        // Phraseology distinguishes climbing, descending and maintaining, but to an
        // aircraft they are one instruction: go to this altitude. What differs is
        // only what the pilot says back, and that comes from the template. Codes
        // that *cannot* collapse this way — "stop climb at" — are deliberately
        // absent, because they must not move an aircraft that is already past the
        // level.
        "101": { flightLevel($0).map { [.altitude(feet: $0)] } ?? [] },   // CLIMB TO FL
        "158": { flightLevel($0).map { [.altitude(feet: $0)] } ?? [] },   // DESCEND TO FL
        "184": { flightLevel($0).map { [.altitude(feet: $0)] } ?? [] },   // CONTINUE DESCENT TO FL
        "219": { flightLevel($0).map { [.altitude(feet: $0)] } ?? [] },   // MAINTAIN FL
        "102": { altitudeFeet($0).map { [.altitude(feet: $0)] } ?? [] },  // CLIMB TO … FEET
        "159": { altitudeFeet($0).map { [.altitude(feet: $0)] } ?? [] },  // DESCEND TO … FEET
        "185": { altitudeFeet($0).map { [.altitude(feet: $0)] } ?? [] },  // CONTINUE DESCENT … FEET
        "220": { altitudeFeet($0).map { [.altitude(feet: $0)] } ?? [] },  // MAINTAIN … FEET

        // MARK: Vertical — blocks
        //
        // The two ends may be given in different units, which one feet-based
        // representation absorbs without a separate case per combination.
        "103": { block(low: flightLevel($0, 0), high: flightLevel($0, 1)) },
        "235": { block(low: flightLevel($0, 0), high: flightLevel($0, 1)) },
        "104": { block(low: altitudeFeet($0, 0), high: altitudeFeet($0, 1)) },
        "236": { block(low: altitudeFeet($0, 0), high: altitudeFeet($0, 1)) },
        "105": { block(low: altitudeFeet($0, 0), high: flightLevel($0, 0)) },
        "237": { block(low: altitudeFeet($0, 0), high: flightLevel($0, 0)) },

        // MARK: Speed
        //
        // Six codes, three effects: "or less" and "do not exceed" are the same
        // ceiling said two ways. Many-to-one is expected here — the codes exist to
        // give each phrasing its own readback.
        "344": { speed($0).map { [.speed($0)] } ?? [] },        // MAINTAIN … KNOTS
        "359": { speed($0).map { [.speed($0)] } ?? [] },        // INCREASE SPEED TO
        "361": { speed($0).map { [.speed($0)] } ?? [] },        // REDUCE SPEED TO
        "346": { speed($0).map { [.minSpeed($0)] } ?? [] },     // … OR GREATER
        "348": { speed($0).map { [.maxSpeed($0)] } ?? [] },     // … OR LESS
        "356": { speed($0).map { [.maxSpeed($0)] } ?? [] },     // DO NOT EXCEED

        // MARK: Level off
        //
        // Kept apart from the plain altitude codes for a reason: "stop climb at
        // FL260" must not move an aircraft that is already above 260.
        "124": { flightLevel($0).map { [.stopClimb(atFeet: $0)] } ?? [] },
        "125": { altitudeFeet($0).map { [.stopClimb(atFeet: $0)] } ?? [] },
        "182": { flightLevel($0).map { [.stopDescent(atFeet: $0)] } ?? [] },
        "183": { altitudeFeet($0).map { [.stopDescent(atFeet: $0)] } ?? [] },

        // MARK: Routing
        "445": { slots in                                        // PROCEED DIRECT TO
            slots.text("WAYPOINT/FIX").map { [.proceedDirect(fix: $0)] } ?? []
        },
        "446": { slots in                                        // GO TO
            slots.text("WAYPOINT/FIX").map { [.proceedDirect(fix: $0)] } ?? []
        },
        // 453 — PROCEED DIRECT TO … AND HOLD AS PUBLISHED, MAINTAIN FLIGHT LEVEL.
        // One phrase, two instructions: the one-to-many case the mapping exists for.
        "453": { slots in
            guard let fix = slots.text("HOLDING FIX"), let feet = flightLevel(slots) else {
                return []
            }
            return [.hold(fix), .altitude(feet: feet)]
        },

        // MARK: Approach
        "454": { slots in                                        // INTERCEPT THE LOCALIZER RWY
            slots.text("NUMBER").map { [.interceptLocalizer(runway: $0)] } ?? []
        },
        // 376 — CLEARED FOR ILS APPROACH RUNWAY.
        //
        // Phraseology separates being vectored onto the localizer from being
        // cleared to fly the approach, but this simulator has one behaviour: track
        // the centreline in and land. So both codes map to the same effect, and the
        // distinction survives where it is actually heard — in the readback. If a
        // full procedure is ever modelled, this is the entry that changes.
        "376": { slots in
            slots.text("NUMBER").map { [.interceptLocalizer(runway: $0)] } ?? []
        },

        // MARK: Clearances
        "436": { slots in                                        // RUNWAY [n] CLEARED FOR TAKEOFF
            [.clearedForTakeoff(runway: slots.text("NUMBER"))]
        },
        "327": { _ in [.goAround] },                             // GO AROUND

        // MARK: Transponder
        "218": { slots in                                        // SQUAWK [CODE]
            slots.text("CODE").map { [.squawk(code: $0)] } ?? []
        },
        // 245 — RADAR FLY HEADING [THREE DIGITS]
        "245": { slots in
            heading(slots).map { [.heading($0)] } ?? []
        },
        // 246 — RADAR TURN LEFT HEADING [THREE DIGITS]
        "246": { slots in
            heading(slots).map { [.headingTurn($0, .left)] } ?? []
        },
        // 247 — RADAR TURN RIGHT HEADING [THREE DIGITS]
        "247": { slots in
            heading(slots).map { [.headingTurn($0, .right)] } ?? []
        },
        // 250 — RADAR TURN LEFT [NUMBER OF DEGREES] DEGREES
        "250": { slots in
            degrees(slots).map { [.relativeTurn($0, .left)] } ?? []
        },
        // 251 — RADAR TURN RIGHT [NUMBER OF DEGREES] DEGREES
        "251": { slots in
            degrees(slots).map { [.relativeTurn($0, .right)] } ?? []
        },
        // 243 — RADAR CONTINUE PRESENT HEADING
        "243": { _ in [.presentHeading] },
        // 254 — RADAR STOP TURN HEADING [THREE DIGITS]
        "254": { slots in
            heading(slots).map { [.stopTurn($0)] } ?? []
        },
    ]

    // MARK: - Confirmations

    /// A value the aircraft actually has, for a reply that has to contradict the
    /// question. Raw rather than spoken: how a level or a squawk is read aloud belongs
    /// to the layer that speaks, not to the simulator.
    public enum ConfirmedValue: Equatable, Sendable {
        case integer(Int)
        case text(String)
    }

    public enum ConfirmationOutcome: Equatable, Sendable {
        /// The question is true of the aircraft — the affirmative reply stands.
        case affirm
        /// It is not. The alternate reply is the one to speak, and these are the values
        /// it needs, keyed by the placeholder that asks for them.
        case negative(actual: [String: ConfirmedValue])
    }

    /// Answers a confirmation question against the aircraft, or nil when the code is
    /// not asking one.
    ///
    /// Some phraseology asks rather than instructs — "confirm flight level two six
    /// zero" — and its readback carries both replies, separated by "If not:". Deciding
    /// which one is true needs the aircraft, so it belongs here with the rest of the
    /// code-to-behaviour mapping. Answering without checking would have the simulator
    /// assert whatever it was asked.
    public static func confirm(code: String,
                               slots: CommandSlots,
                               aircraft: Aircraft,
                               context: Context) -> ConfirmationOutcome? {
        switch code {
        case "430":   // CONFIRM [LEVEL]
            guard let asked = slots.integer("LEVEL") else { return nil }
            let actual = aircraft.flightLevel
            return asked == actual
                ? .affirm
                : .negative(actual: ["ACTUAL LEVEL": .integer(actual)])

        case "216":   // CONFIRM SQUAWK [CODE]
            guard let asked = slots.text("CODE") else { return nil }
            return asked == aircraft.squawk
                ? .affirm
                : .negative(actual: ["ACTUAL CODE": .text(aircraft.squawk)])

        case "409":   // CONFIRM ESTABLISHED ON ILS LOCALIZER
            // Established means cleared for the localizer and actually inside its cone.
            guard let runway = aircraft.interceptRunway,
                  LocalizerGuidanceService.isInCone(aircraft: aircraft, runway: runway,
                                                    runways: context.runways) else {
                return .negative(actual: [:])
            }
            return .affirm

        default:
            return nil
        }
    }

    /// Scene inputs a confirmation may need. Aliased so callers pass the same context
    /// they already build for validation.
    public typealias Context = CommandValidator.Context

    /// Codes whose reply cannot be given without the aircraft.
    ///
    /// Listed so a caller can refuse rather than guess. Answering one of these without
    /// having found the aircraft means asserting something unchecked — the affirmative
    /// branch of a confirmation, or a heading nobody read.
    public static let answeredFromAircraft: Set<String> = [
        "216",   // CONFIRM SQUAWK
        "258",   // REPORT HEADING AND FLIGHT LEVEL
        "409",   // CONFIRM ESTABLISHED ON ILS LOCALIZER
        "430",   // CONFIRM [LEVEL]
        "443",   // REPORT RADIALS
    ]

    // MARK: - Values only the aircraft knows

    /// Fills the slots a readback asks for that the instruction never supplied.
    ///
    /// Some phraseology asks the pilot to state something: its own heading and level,
    /// or its radial from a VOR. The request carries no such value, so the readback is
    /// left with unfillable slots — and a phrase that cannot be completed is not spoken
    /// at all, which is how "report heading and flight level" came to be answered with
    /// silence. The aircraft is what knows these, so supplying them belongs here.
    ///
    /// Returns nil when the code asks for nothing of the sort, and an empty dictionary
    /// when it does but the scene cannot answer — a caller can then say so rather than
    /// going quiet.
    public static func reportedValues(code: String,
                                      aircraft: Aircraft,
                                      context: Context) -> [String: ConfirmedValue]? {
        switch code {
        case "258":   // REPORT HEADING AND FLIGHT LEVEL
            return ["THREE DIGITS": .integer(Int(aircraft.headingDegrees.rounded()) % 360),
                    "LEVEL": .integer(aircraft.flightLevel)]

        case "443":   // REPORT RADIALS
            guard let vor = nearestVOR(to: aircraft, in: context.navigationFixes),
                  let position = FixLookup.coordinate(of: vor),
                  let name = vor.fixName else { return [:] }
            // The radial is the bearing measured *from* the station outward, which is
            // the reverse of the bearing an aircraft would fly to reach it.
            let radial = Int(Geo.bearing(from: position, to: aircraft.position).rounded()) % 360
            return ["THREE DIGITS": .integer(radial), "VOR NAME": .text(name)]

        default:
            return nil
        }
    }

    /// Closest VOR to the aircraft, or nil when the exercise has none.
    private static func nearestVOR(to aircraft: Aircraft, in fixes: [Fix]) -> Fix? {
        fixes
            .filter { $0.type?.uppercased() == "VOR" }
            .compactMap { fix -> (fix: Fix, distance: Double)? in
                guard let position = FixLookup.coordinate(of: fix) else { return nil }
                return (fix, Geo.distanceMeters(from: aircraft.position, to: position))
            }
            .min { $0.distance < $1.distance }?
            .fix
    }

    // MARK: - Deferred reports

    /// When a "report …" instruction should actually be reported.
    ///
    /// These templates carry a `Later:` branch in their readback — the pilot says
    /// WILCO now and reports when the condition occurs. The words come from the
    /// template; deciding *when* needs position and geometry, so it belongs here
    /// with the rest of the code-to-behaviour mapping.
    ///
    /// Returns nil for codes that ask for nothing deferred.
    public static func reportCondition(code: String, slots: CommandSlots) -> ReportCondition? {
        switch code {
        case "316":   // REPORT PASSING [SIGNIFICANT POINT]
            return slots.text("SIGNIFICANT POINT").map { .passingFix($0) }

        case "317":   // REPORT [DISTANCE] MILES GNSS FROM [DME STATION]
            return distanceReport(slots, fixSlot: "DME STATION")
        case "318":   // … GNSS FROM [SIGNIFICANT POINT]
            return distanceReport(slots, fixSlot: "SIGNIFICANT POINT")
        case "319":   // … DME FROM [DME STATION]
            return distanceReport(slots, fixSlot: "DME STATION")
        case "320":   // … DME FROM [SIGNIFICANT POINT]
            return distanceReport(slots, fixSlot: "SIGNIFICANT POINT")

        case "405":   // REPORT ESTABLISHED ON ILS LOCALIZER
            return .establishedOnLocalizer

        default:
            return nil
        }
    }

    private static func distanceReport(_ slots: CommandSlots,
                                       fixSlot: String) -> ReportCondition? {
        guard let miles = slots.integer("DISTANCE"), let fix = slots.text(fixSlot) else {
            return nil
        }
        return .distanceFromFix(nauticalMiles: Double(miles), fix: fix)
    }

    // MARK: - Slot readers

    /// Heading 360 and heading 0 are the same direction; the simulator stores it
    /// as 0 so comparisons behave.
    private static func heading(_ slots: CommandSlots) -> Double? {
        guard let value = slots.integer("THREE DIGITS") else { return nil }
        return Double(value == 360 ? 0 : value)
    }

    private static func degrees(_ slots: CommandSlots) -> Double? {
        slots.integer("NUMBER OF DEGREES").map(Double.init)
    }

    /// `[LEVEL]` — a flight level, converted to the feet the aircraft flies.
    private static func flightLevel(_ slots: CommandSlots, _ occurrence: Int = 0) -> Double? {
        slots.integer("LEVEL", occurrence: occurrence).map { Double($0) * 100 }
    }

    /// `[ALTITUDE]` — already feet.
    private static func altitudeFeet(_ slots: CommandSlots, _ occurrence: Int = 0) -> Double? {
        slots.integer("ALTITUDE", occurrence: occurrence).map(Double.init)
    }

    private static func speed(_ slots: CommandSlots) -> Double? {
        slots.integer("NUMBER").map(Double.init)
    }

    /// A block needs both ends; one missing value makes the whole instruction
    /// unusable rather than half-applied.
    private static func block(low: Double?, high: Double?) -> [AircraftCommand] {
        guard let low, let high else { return [] }
        return [.altitudeBlock(lowFeet: min(low, high), highFeet: max(low, high))]
    }
}
