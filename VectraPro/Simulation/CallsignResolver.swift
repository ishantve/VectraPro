//
//  CallsignResolver.swift
//  VectraPro
//
//  Resolves a callsign from an already-normalised voice transcript, extracted
//  from MapViewModel. Stateless: the candidate aircraft and airline table are
//  passed in. MapViewModel keeps the thin wrappers that decide which aircraft
//  are candidates (departures, live radar, holding).
//

import Foundation

enum CallsignResolver {

    /// Direct ICAO match → spoken airline name + flight number.
    /// Returns the matched callsign, or nil if nothing matches.
    static func resolve(from normalizedText: String,
                        among candidates: [Aircraft],
                        airlines: [ExerciseDetail.Airline]) -> String? {
        let text = normalizedText.lowercased()
        // 1. Direct match — "aic235" or spaced form "aca 29" both match callsign "ACA29".
        for ac in candidates {
            let cs = ac.callsign.lowercased()
            if text.contains(cs) { return ac.callsign }
            // Spoken callsigns often have a space between letter prefix and digits.
            let letters = String(cs.prefix(while: { $0.isLetter }))
            let digits  = String(cs.drop(while:  { $0.isLetter }))
            if !letters.isEmpty && !digits.isEmpty && text.contains("\(letters) \(digits)") {
                return ac.callsign
            }
        }
        // 2. Airline spoken name + flight number — e.g. "air india 235".
        for airline in airlines {
            guard let spoken = airline.callSign?.lowercased().trimmingCharacters(in: .whitespaces),
                  !spoken.isEmpty,
                  let icao = airline.icaoCode?.uppercased(), !icao.isEmpty,
                  let nameRange = text.range(of: spoken) else { continue }
            let after  = String(text[nameRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            let digits = String(after.prefix(while: { $0.isNumber || $0 == " " })
                                     .filter(\.isNumber).prefix(4))
            guard !digits.isEmpty else { continue }
            let candidate = icao + digits
            if candidates.contains(where: { $0.callsign.uppercased() == candidate }) {
                return candidate
            }
        }
        return nil
    }
}
