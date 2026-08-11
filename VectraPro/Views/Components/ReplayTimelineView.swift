//
//  ReplayTimelineView.swift
//  VectraPro
//
//  The replay timeline panel: every recorded event of the open recording, in order, as a human-readable line
//  with an MM:SS timestamp. Tapping a line seeks the live replay to that event's tick through the existing
//  `ReplayTransport` — this view owns no clock and no seeking logic of its own. The entry the replay is
//  currently at is highlighted, and the highlight follows both a tap-seek and ordinary playback because it is
//  derived from the shared `ReplayClock.position`.
//
//  Styling reuses the app's popup design language (the navy MenuCard card + the FlightData title-bar/X).
//

import SwiftUI
import ATCReplayKit

struct ReplayTimelineView: View {

    let sessionID: SessionID
    let title: String

    /// The live transport of the replay this panel sits over. Seeking goes through it — the one seek path.
    let transport: ReplayTransport

    /// The replay's clock, observed so the highlighted row tracks the current position as playback advances.
    @ObservedObject var clock: ReplayClock

    let onClose: () -> Void

    @StateObject private var model = ReplayTimelineViewModel()

    // App popup tokens (match MenuCard / navy panel family).
    private let panelBG = Color(red: 0.06, green: 0.10, blue: 0.18).opacity(0.97)
    private let accent = Color(red: 0.32, green: 0.56, blue: 0.95)

    private var currentID: Int? { model.currentEntryID(atPosition: clock.position) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.12))
            content
        }
        .frame(width: 440, height: 540)
        .background(panelBG, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(accent.opacity(0.7), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
        .onAppear { model.load(sessionID: sessionID, using: SessionCoordinator.shared.sessions) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.85))
            VStack(alignment: .leading, spacing: 1) {
                Text("Replay Timeline")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if let failure = model.failure {
            centered(Text("Could not read the log\n\(failure)")
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center))
        } else if model.isLoaded && model.entries.isEmpty {
            centered(Text("No events to show for this recording.")
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)))
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.entries) { entry in
                            row(entry, isCurrent: entry.id == currentID)
                            Divider().overlay(.white.opacity(0.08))
                        }
                    }
                    .padding(.vertical, 4)
                }
                // Keep the current row in view as it moves — on tap-seek and as playback advances.
                .onChange(of: currentID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private func row(_ entry: ReplayLogEntry, isCurrent: Bool) -> some View {
        Button {
            // The one seek path. Preserves play/pause via ReplayClock's begin/endSeeking — playing keeps
            // playing from here, paused stays paused.
            transport.perform(.seek(tick: entry.tick))
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(entry.timestamp)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isCurrent ? accent : .white.opacity(0.55))
                Text(entry.text)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(isCurrent ? 1 : 0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(isCurrent ? accent.opacity(0.18) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(entry.id)
    }

    private func centered<V: View>(_ v: V) -> some View {
        VStack { Spacer(); v.padding(24); Spacer() }.frame(maxWidth: .infinity)
    }
}
