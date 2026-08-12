//
//  ReplayTimelineView.swift
//  VectraPro
//
//  The replay log for a recording: every recorded event, in order, as a human-readable line with an MM:SS
//  timestamp. It is a **read-only** list shown in place inside the recordings popup — not over the radar —
//  so it carries no replay clock and no seeking: it reads the recording's events through the session manager
//  and describes them through `ReplayEventDescriptor`.
//
//  It reads through the *same* `SessionManager` the browser listed the recording from, so what it shows can
//  never diverge from the row that opened it.
//

import SwiftUI
import ATCReplayKit

struct ReplayTimelineView: View {

    let sessionID: SessionID

    /// The manager the recording was listed from — read the log through the very same store, so a row that
    /// exists always resolves to the same events.
    let sessions: SessionManager

    @StateObject private var model = ReplayTimelineViewModel()

    private let accent = Color(red: 0.32, green: 0.56, blue: 0.95)

    var body: some View {
        content
            .onAppear { model.load(sessionID: sessionID, using: sessions) }
    }

    @ViewBuilder
    private var content: some View {
        if let failure = model.failure {
            centered("Could not read the log", failure, "exclamationmark.triangle")
        } else if !model.isLoaded {
            centered(nil, nil, nil)   // brief, before the first load returns
        } else if model.entries.isEmpty {
            if model.rawEventCount > 0 {
                // Events on disk, none shown: a log this build can't read (e.g. an older recording format),
                // not an empty session — say so rather than imply nothing happened.
                centered("Couldn't read this recording's log",
                         "It holds \(model.rawEventCount) event\(model.rawEventCount == 1 ? "" : "s") in a format this version can't display.",
                         "exclamationmark.triangle")
            } else {
                centered("No events in this recording", "This session recorded no instructions or read-backs.",
                         "list.bullet.rectangle")
            }
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.entries) { entry in
                        row(entry)
                        Divider().overlay(.white.opacity(0.08))
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func row(_ entry: ReplayLogEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(entry.timestamp)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(accent.opacity(0.85))
            Text(entry.text)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private func centered(_ title: String?, _ subtitle: String?, _ symbol: String?) -> some View {
        VStack(spacing: 10) {
            Spacer()
            if let symbol {
                Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.white.opacity(0.4))
            }
            if let title {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            }
            if let subtitle {
                Text(subtitle).font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
