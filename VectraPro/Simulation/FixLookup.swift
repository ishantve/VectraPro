//
//  FixLookup.swift
//  VectraPro
//
//  Tolerant fix-name matching and coordinate lookup, extracted from MapViewModel.
//  Stateless: the fix list is passed in. Matching ignores case, hyphens and
//  spaces so spoken codes match hyphenated fix names ("re01" ↔ "RE-01").
//

import CoreLocation

enum FixLookup {

    /// Strips everything but letters and digits and lowercases — for tolerant
    /// fix-name matching.
    static func canonical(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Find a fix by name within the given list, ignoring case/hyphens/spaces.
    static func fix(named name: String, in fixes: [ExerciseDetail.Fix]) -> ExerciseDetail.Fix? {
        let target = canonical(name)
        return fixes.first { canonical($0.fixName ?? "") == target }
    }

    /// The coordinate of a fix, if it has valid lat/lon.
    static func coordinate(of fix: ExerciseDetail.Fix) -> CLLocationCoordinate2D? {
        guard let lat = fix.latitude, let lon = fix.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// The coordinate of a fix looked up by name.
    static func position(named name: String, in fixes: [ExerciseDetail.Fix]) -> CLLocationCoordinate2D? {
        guard let f = fix(named: name, in: fixes) else { return nil }
        return coordinate(of: f)
    }
}
