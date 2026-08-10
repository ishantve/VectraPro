//
//  CommandTemplateStore.swift
//  VectraPro
//
//  Supplies the phraseology vocabulary to the parser.
//
//  The parser takes templates as an input and never fetches them, so that it stays
//  free of networking and works the same on every platform. Loading them is this
//  layer's job.
//
//  Right now the only source is a copy bundled with the app. There is no backend
//  route for phraseology yet — `APIEndpoint` has no case for it — so this is the
//  seam where one goes: `load()` gains a fetch, keeps the bundled copy as the
//  offline and first-launch fallback, and nothing above here changes. A bundled
//  fallback is needed regardless; a radar screen that cannot parse instructions
//  because the network is down is worse than one running slightly stale wording.
//
//  Diagnostics from decoding are logged rather than swallowed. They are the list
//  of data problems to send back to whoever maintains the payload — two entries
//  with no `abbreviationCode`, a template and its readback disagreeing about a
//  placeholder — and they will not surface any other way.
//

import Foundation
import ATCParserKit

final class CommandTemplateStore {

    static let shared = CommandTemplateStore()

    /// Nil when the vocabulary could not be loaded at all; callers fall back to
    /// the legacy parser rather than losing command input entirely.
    private(set) var recognizer: CommandRecognizer?

    private(set) var templates: TemplateSet?

    private init() {
        load()
    }

    /// Bundled name; also the fallback if a fetched payload ever fails to decode.
    private static let bundledResource = "CommandTemplates"

    /// Payload entries that cannot be used as shipped.
    ///
    /// Code 320 asks the pilot to report a distance "FROM [SIGNIFICANT POINT]" but
    /// its readback names [DME STATION], which the instruction never supplies — so
    /// the reply has an unfillable slot and can never be spoken. The template is
    /// right and the readback is the copy-paste slip, so the readback is corrected
    /// here. The decoder still reports the mismatch, and this entry goes away once
    /// the payload is fixed at source.
    private static let corrections: [TemplateSet.Correction] = [
        .init(id: "320",
              readback: "WILCO, [CALLSIGN]. Later: [CALLSIGN], "
                      + "[DISTANCE] MILES DME FROM [SIGNIFICANT POINT]."),
    ]

    func load() {
        guard let url = Bundle.main.url(forResource: Self.bundledResource,
                                        withExtension: "json") else {
            log("CommandTemplates.json missing from the bundle — falling back to the legacy parser")
            return
        }
        do {
            let set = try TemplateSet(data: try Data(contentsOf: url))
                .applying(Self.corrections)
            templates = set
            recognizer = CommandRecognizer(templates: set)
            report(set)
        } catch {
            log("phraseology payload failed to decode: \(error)")
        }
    }

    /// Surfaces what had to be worked around in the payload.
    private func report(_ set: TemplateSet) {
        log("loaded \(set.templates.count) templates in \(set.categories.count) categories "
            + "(\(set.disabled.count) disabled)")
        guard !set.diagnostics.isEmpty else { return }
        log("\(set.diagnostics.count) data issues in the phraseology payload:")
        for diagnostic in set.diagnostics { log("  • \(diagnostic)") }
    }

    private func log(_ message: String) {
        #if DEBUG
        print("[CommandTemplateStore] \(message)")
        #endif
    }
}
