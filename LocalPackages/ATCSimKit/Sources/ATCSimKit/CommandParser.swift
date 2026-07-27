//
//  CommandParser.swift
//  VectraPro
//
//  Two-step ATC voice command parser.
//
//  Step 1 — normalize():
//    • Lowercase
//    • Strip punctuation / special characters  (keeps letters, digits, spaces)
//    • Expand spoken digit words  ("two seven zero" → "270")
//    • Collapse extra whitespace
//
//  Step 2 — extractCallsign(from:):
//    Heuristic: everything BEFORE the first ATC command keyword that ends
//    with 1–4 digits is treated as the callsign.  No airline database needed.
//    Examples:
//      "air canada 125 heading 270"   → callsign "air canada 125"
//      "aca 125 heading 270"          → callsign "aca 125"
//      "indigo 2341 speed 280"        → callsign "indigo 2341"
//      "japan airlines 123 fl 350"    → callsign "japan airlines 123"
//      "heading 270"                  → no callsign (plain command)
//
//  Step 3 — parse():
//    • Heading   : "turn left heading 270" / "fly heading 090"
//    • FL        : "climb flight level 250" / "FL250"
//    • Block alt : "maintain block flight level 100 through 120"
//    • Speed     : "speed 250" / "maintain 250 knots"
//    • Min speed : "maintain 250 knots or greater"
//    • Max speed : "do not exceed 250 knots"
//    • Present heading : "present heading"
//

import Foundation

public struct CommandParser {

    // ─────────────────────────────────────────────
    // MARK: Step 1 · Normalise
    // ─────────────────────────────────────────────

    /// Returns a clean, lowercase string ready for pattern matching.
    /// Always call this before extractCallsign() or parse().
    public static func normalize(_ raw: String) -> String {
        var text = raw.lowercased()

        // Keep only letters, digits, and spaces — drop commas, periods,
        // dashes, apostrophes, and every other punctuation / special character.
        text = text.unicodeScalars
            .filter {
                CharacterSet.letters
                    .union(.decimalDigits)
                    .union(.whitespaces)
                    .contains($0)
            }
            .map { String($0) }
            .joined()

        // Expand spoken digit words → numeric tokens.
        text = expandDigitWords(text)

        // Collapse any run of whitespace to a single space.
        text = text.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression
        )

        return text.trimmingCharacters(in: .whitespaces)
    }

    // ─────────────────────────────────────────────
    // MARK: Step 2 · Callsign extraction
    // ─────────────────────────────────────────────

    /// ATC command keywords used to find where the callsign ends
    /// and the instruction begins.
    private static let commandKeywords: [String] = [
        "present heading",
        "flight level",
        "turn left",
        "turn right",
        "heading",
        "climb",
        "descend",
        "maintain",
        "reduce speed",
        "decrease speed",
        "increase speed",
        "speed",
        "knots",
        "or greater",
        "not exceed",
        "exceed",
        "contact",
        "squawk",
        "direct",
        "hold",
        "intercept"
    ]

    /// Result of callsign extraction.
    public struct Extracted {
        /// Raw callsign text as it appeared in the transcript (already normalised).
        public let callsign: String
        /// Remainder of the string with the callsign prefix removed.
        public let commandText: String
    }

    /// Identifies and strips a callsign prefix from a normalised transcript.
    ///
    /// Heuristic:
    ///   1. Find the earliest ATC command keyword in the string.
    ///   2. Everything before that keyword is the candidate prefix.
    ///   3. The candidate must end with 1–4 digits (the flight number).
    ///   4. If all three conditions hold, the prefix is the callsign.
    ///
    /// Works for any airline worldwide — no lookup table required.
    public static func extractCallsign(from normalized: String) -> Extracted? {
        // 1. Find the index of the earliest command keyword.
        var firstKeywordIndex: String.Index? = nil
        for keyword in commandKeywords {
            guard let r = normalized.range(of: keyword) else { continue }
            if firstKeywordIndex == nil || r.lowerBound < firstKeywordIndex! {
                firstKeywordIndex = r.lowerBound
            }
        }

        // Need a keyword AND text before it.
        guard let kwIdx = firstKeywordIndex,
              kwIdx > normalized.startIndex else { return nil }

        let prefix = String(normalized[..<kwIdx])
            .trimmingCharacters(in: .whitespaces)

        // 2. Prefix must not be empty.
        guard !prefix.isEmpty else { return nil }

        // 3. Prefix must end with 1–4 digits (the flight number).
        guard prefix.range(of: "\\d{1,4}$", options: .regularExpression) != nil else {
            return nil
        }

        let commandText = String(normalized[kwIdx...])
            .trimmingCharacters(in: .whitespaces)

        return Extracted(callsign: prefix, commandText: commandText)
    }

    // ─────────────────────────────────────────────
    // MARK: Step 3 · Parse commands
    // ─────────────────────────────────────────────

    /// Extract all recognised ATC commands from an already-normalised string.
    /// Pass the `commandText` from extractCallsign() here, not the full transcript,
    /// so flight-number digits cannot collide with command values.
    public static func parse(_ normalized: String) -> [AircraftCommand] {
        var commands: [AircraftCommand] = []
        if normalized.contains("present heading")  { commands.append(AircraftCommand.presentHeading) }
        if let c = parseInterceptLocalizer(normalized) { commands.append(c) }
        if let c = parseHold(normalized)            { commands.append(c) }
        if let c = parseHeading(normalized)         { commands.append(c) }
        if let c = parseFlightLevel(normalized)     { commands.append(c) }
        if let c = parseSpeed(normalized)           { commands.append(c) }
        return commands
    }

    // ─────────────────────────────────────────────
    // MARK: Intercept localizer
    // ─────────────────────────────────────────────

    /// "intercept the localizer runway 27 left" → .interceptLocalizer("27L").
    /// Requires "intercept" + "localizer"/"loc" + "runway <number>" with an
    /// optional left / right / center suffix.
    private static func parseInterceptLocalizer(_ text: String) -> AircraftCommand? {
        guard text.contains("intercept"),
              text.contains("localizer") || text.contains("localiser") || text.contains(" loc"),
              let rwyRange = text.range(of: "runway"),
              let number = firstInt(after: rwyRange.upperBound, in: text),
              (1...36).contains(number) else { return nil }

        let after = text[rwyRange.upperBound...]
        let suffix: String
        if after.contains("left")                              { suffix = "L" }
        else if after.contains("right")                        { suffix = "R" }
        else if after.contains("center") || after.contains("centre") { suffix = "C" }
        else                                                   { suffix = "" }

        return .interceptLocalizer(runway: "\(number)\(suffix)")
    }

    // ─────────────────────────────────────────────
    // MARK: Hold
    // ─────────────────────────────────────────────

    /// "hold at papa juliet" → .hold("PJ"), "hold at bravo romeo" → .hold("BR"),
    /// "hold at pj" → .hold("pj"). The fix name is the text after "hold [at]";
    /// spoken ICAO phonetic words are folded into a letter code.
    private static func parseHold(_ text: String) -> AircraftCommand? {
        guard let r = text.range(of: "hold") else { return nil }
        var rest = String(text[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("at ") {
            rest = String(rest.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        } else if rest == "at" {
            rest = ""
        }
        guard !rest.isEmpty else { return nil }

        // Fold spoken ICAO phonetic words + digits into a compact code:
        //   "papa juliet"        → "PJ"
        //   "romeo echo 01"      → "RE01"   (matches fix "RE-01")
        //   "victor india 95"    → "VI95"
        // If any token is a plain word (a full fix name like "clink"), keep the
        // words joined as-is ("vi 95" → "vi95", "clink" → "clink").
        let words = rest.split(separator: " ").map(String.init)
        let allPhoneticOrDigits = words.allSatisfy {
            phoneticMap[$0] != nil || $0.allSatisfy(\.isNumber)
        }
        if allPhoneticOrDigits {
            return .hold(words.map { phoneticMap[$0] ?? $0 }.joined())
        }
        return .hold(words.joined())
    }

    /// ICAO phonetic alphabet → letter (spelling for callsigns / fix codes).
    private static let phoneticMap: [String: String] = [
        "alpha": "A", "alfa": "A", "bravo": "B", "charlie": "C", "delta": "D",
        "echo": "E", "foxtrot": "F", "golf": "G", "hotel": "H", "india": "I",
        "juliet": "J", "juliett": "J", "kilo": "K", "lima": "L", "mike": "M",
        "november": "N", "oscar": "O", "papa": "P", "quebec": "Q", "romeo": "R",
        "sierra": "S", "tango": "T", "uniform": "U", "victor": "V", "whiskey": "W",
        "xray": "X", "yankee": "Y", "zulu": "Z"
    ]

    // ─────────────────────────────────────────────
    // MARK: Heading
    // ─────────────────────────────────────────────

    private static func parseHeading(_ text: String) -> AircraftCommand? {
        guard let kwRange = text.range(of: "heading"),
              let value   = firstInt(after: kwRange.upperBound, in: text),
              (1...360).contains(value)
        else { return nil }

        let hdg    = Double(value == 360 ? 0 : value)
        let before = String(text[..<kwRange.lowerBound])

        if before.contains("left")  { return .headingTurn(hdg, .left)  }
        if before.contains("right") { return .headingTurn(hdg, .right) }
        return .heading(hdg)
    }

    // ─────────────────────────────────────────────
    // MARK: Flight level / altitude block
    // ─────────────────────────────────────────────

    private static func parseFlightLevel(_ text: String) -> AircraftCommand? {
        // Block: "maintain block flight level 100 through 120"
        if text.contains("block") {
            let nums = allInts(in: text)
            if nums.count >= 2 {
                return .altitudeBlock(low: min(nums[0], nums[1]),
                                      high: max(nums[0], nums[1]))
            }
        }

        // "flight level 250" / "climb flight level 100"
        if let r = text.range(of: "flight level"),
           let num = firstInt(after: r.upperBound, in: text) {
            return .flightLevel(num)
        }

        // "FL250" / "fl 250"
        if let r = text.range(of: "fl\\s*\\d{2,3}", options: .regularExpression),
           let num = Int(text[r].filter(\.isNumber)) {
            return .flightLevel(num)
        }

        return nil
    }

    // ─────────────────────────────────────────────
    // MARK: Speed
    // ─────────────────────────────────────────────

    private static func parseSpeed(_ text: String) -> AircraftCommand? {
        // "maintain 250 knots or greater" → minSpeed
        if text.contains("or greater"),
           let r   = text.range(of: "or greater"),
           let num = lastInt(before: r.lowerBound, in: text) {
            return .minSpeed(Double(num))
        }

        // "do not exceed 250" / "not exceed 250" → maxSpeed
        if text.contains("exceed"),
           let r   = text.range(of: "exceed"),
           let num = firstInt(after: r.upperBound, in: text) {
            return .maxSpeed(Double(num))
        }

        // "speed 250" / "reduce speed 250" / "increase speed 250"
        if let r   = text.range(of: "speed"),
           let num = firstInt(after: r.upperBound, in: text),
           num > 0 {
            return .speed(Double(num))
        }

        // "maintain 250 knots" (no "or greater")
        if let r   = text.range(of: "knots"),
           let num = lastInt(before: r.lowerBound, in: text),
           num > 0 {
            return .speed(Double(num))
        }

        return nil
    }

    // ─────────────────────────────────────────────
    // MARK: Digit-word expansion
    // ─────────────────────────────────────────────

    private static let digitWordMap: [String: String] = [
        "zero": "0", "oh": "0",
        "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
        "six": "6", "seven": "7", "eight": "8", "nine": "9", "niner": "9"
    ]

    private static func expandDigitWords(_ text: String) -> String {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true)
        let mapped = tokens.map { digitWordMap[String($0)] ?? String($0) }
        var result = mapped.joined(separator: " ")
        // "2 7 0" → "270": collapse spaces between adjacent digit tokens.
        result = result.replacingOccurrences(
            of: "(?<=\\d) (?=\\d)", with: "", options: .regularExpression
        )
        return result
    }

    // ─────────────────────────────────────────────
    // MARK: Integer extraction helpers
    // ─────────────────────────────────────────────

    /// First 1–3 digit integer at or after `index`.
    private static func firstInt(after index: String.Index, in text: String) -> Int? {
        let sub = text[index...]
        guard let m = sub.range(of: "\\d{1,3}", options: .regularExpression) else { return nil }
        return Int(sub[m])
    }

    /// Last 1–3 digit integer strictly before `index`.
    private static func lastInt(before index: String.Index, in text: String) -> Int? {
        let sub = text[..<index]
        guard let m = sub.range(of: "\\d{1,3}",
                                 options: [.regularExpression, .backwards]) else { return nil }
        return Int(sub[m])
    }

    /// All integers found in `text`, in left-to-right order.
    private static func allInts(in text: String) -> [Int] {
        var results: [Int] = []
        var search = text.startIndex..<text.endIndex
        while let m = text.range(of: "\\d{1,3}", options: .regularExpression, range: search) {
            if let n = Int(text[m]) { results.append(n) }
            search = m.upperBound..<text.endIndex
        }
        return results
    }
}
