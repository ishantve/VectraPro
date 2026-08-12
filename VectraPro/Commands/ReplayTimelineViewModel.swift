//
//  ReplayTimelineViewModel.swift
//  VectraPro
//
//  Presentation state for the replay timeline: the recording's events, turned into human-readable, time-
//  stamped rows, ordered as they happened. It reads events through the session manager and describes them
//  through `ReplayEventDescriptor`; it holds no replay clock of its own and computes no positions — seeking
//  stays with `ReplayTransport`, and `position` for highlighting is read from the existing `ReplayClock`.
//

import Combine
import Foundation
import ATCReplayKit

/// One line of the timeline. `tick` is the canonical replay position (simulated seconds); `ordinal` only
/// orders events that share a tick and is never shown.
struct ReplayLogEntry: Identifiable, Equatable {
    let id: Int
    let tick: Int
    let ordinal: UInt32
    let timestamp: String   // MM:SS, from tick — the model has no finer replay time
    let text: String
}

@MainActor
final class ReplayTimelineViewModel: ObservableObject {

    @Published private(set) var entries: [ReplayLogEntry] = []
    @Published private(set) var failure: String?
    @Published private(set) var isLoaded = false

    /// How many events the recording held before description/filtering. Lets the UI tell "recorded nothing"
    /// (0) apart from "recorded events none of which could be shown" (> 0 with no entries) — e.g. a log in a
    /// format this build no longer reads — instead of one blank that hides which it was.
    @Published private(set) var rawEventCount = 0

    private let descriptor: ReplayEventDescriptor

    init(descriptor: ReplayEventDescriptor = .shared) {
        self.descriptor = descriptor
    }

    nonisolated deinit { }

    /// Builds the timeline for a recording. Reads the whole event log once (a recording is on the order of a
    /// thousand events — the read + decode is small), orders by `(tick, ordinal)`, and drops entries the
    /// descriptor excludes (foreign payloads, playback-control markers). Rendering is lazy in the view.
    func load(sessionID: SessionID, using sessions: SessionManager) {
        do {
            let events = try sessions.events(for: sessionID).sorted { $0.position < $1.position }
            var built: [ReplayLogEntry] = []
            built.reserveCapacity(events.count)
            for event in events {
                guard let text = descriptor.describe(event) else { continue }   // skip foreign / playback markers
                built.append(ReplayLogEntry(id: built.count,
                                            tick: event.tick,
                                            ordinal: event.ordinal,
                                            timestamp: Self.mmss(event.tick),
                                            text: text))
            }
            entries = built
            rawEventCount = events.count
            failure = nil
        } catch {
            entries = []
            rawEventCount = 0
            failure = "\(error)"
        }
        isLoaded = true
    }

    /// The entry the replay is currently at: the last one whose tick has been reached. Drives the highlight;
    /// nil before the first entry's tick.
    func currentEntryID(atPosition position: Int) -> Int? {
        entries.last { $0.tick <= position }?.id
    }

    static func mmss(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
