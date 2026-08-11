//
//  ReplayBrowserView.swift
//  VectraPro
//
//  The recordings a trainee can replay, and the branches that came out of them.
//
//  Reads the catalogue, which is why it can list two hundred sessions without opening one: everything shown here —
//  duration, class, state, whether it can be scored — is a row, not a recording.
//
//  Branch visibility is indentation. Deliberately plain: the lineage that matters is "this came out of that", and a
//  tree drawing would be more work than the information justifies today.
//

import SwiftUI
import ATCReplayKit

struct ReplayBrowserView: View {

    let coordinator: SessionCoordinator

    /// Show only this exercise's recordings.
    ///
    /// The browser opens from a button on an exercise card, so the question being asked is "what have I flown of
    /// *this*" — an unfiltered list would answer a question nobody asked from here. Nil lists everything, which is
    /// what a future "all my sessions" screen wants.
    var exerciseName: String?

    let onSelect: (SessionID) -> Void

    @Environment(\.dismiss) private var dismiss

    /// One row plus how deep in a lineage it sits. Loaded once on appear — the catalogue is the source, and
    /// re-reading it per frame would be a query per scroll.
    @State private var rows: [(summary: SessionSummary, depth: Int)] = []
    @State private var failure: String?

    private let environment = RecordingEnvironment.current()

    var body: some View {
        NavigationStack {
            Group {
                if let failure {
                    ContentUnavailableView("Could not read recordings", systemImage: "exclamationmark.triangle",
                                           description: Text(failure))
                } else if rows.isEmpty {
                    ContentUnavailableView("No recordings yet", systemImage: "record.circle",
                                           description: Text("Fly an exercise and it will appear here."))
                } else {
                    List(rows, id: \.summary.id) { row in
                        SessionRow(summary: row.summary,
                                   depth: row.depth,
                                   environment: environment,
                                   logURL: coordinator.sessions.eventLogURL(for: row.summary.id)) {
                            onSelect(row.summary.id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(exerciseName ?? "Recordings")
            .toolbar { Button("Done") { dismiss() } }
        }
        .task { load() }
    }

    /// Roots first, each followed by its descendants — so a branch reads as belonging to what it came from.
    ///
    /// Filtering happens before the tree is built, and a branch whose parent was filtered out becomes a root. That
    /// is the right answer here: a session that is in the list must be reachable, and hiding it because its parent
    /// belongs to another exercise would strand it.
    private func load() {
        do {
            var all = try coordinator.sessions.catalogue.allSessions()
            if let exerciseName {
                all = all.filter { $0.exerciseName == exerciseName }
            }
            let present = Set(all.map(\.id))
            let byParent = Dictionary(grouping: all.filter { $0.parentID != nil }) { $0.parentID! }

            func walk(_ summary: SessionSummary, depth: Int) -> [(SessionSummary, Int)] {
                [(summary, depth)] + (byParent[summary.id] ?? []).flatMap { walk($0, depth: depth + 1) }
            }
            rows = all.filter { $0.parentID == nil || !present.contains($0.parentID!) }
                .flatMap { walk($0, depth: 0) }
        } catch {
            failure = "\(error)"
        }
    }
}

/// One recording, as a list row.
///
/// Not private so a snapshot harness can render it at several widths without standing up a catalogue.
struct SessionRow: View {

    let summary: SessionSummary
    let depth: Int
    let environment: RecordingEnvironment

    /// The sealed log, for sharing.
    let logURL: URL

    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if depth > 0 {
                // A branch. Rail, then glyph: at 16pt a step was almost invisible on a 1194pt-wide row, so depth
                // two read the same as depth one. The rails make the level countable instead of estimated.
                HStack(spacing: 0) {
                    ForEach(0..<depth, id: \.self) { _ in
                        Rectangle()
                            .fill(.quaternary)
                            .frame(width: 1)
                            .frame(width: 26, alignment: .leading)
                    }
                }
                .frame(height: 34)

                Image(systemName: "arrow.turn.down.right")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(summary.label.isEmpty ? "Exercise" : summary.label)
                        .font(.body.weight(.semibold))
                    if summary.sessionClass == .assessment {
                        Text("ASSESSMENT")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Why it cannot be scored, said up front — an instructor should not spend twenty minutes on a
                // review before finding out.
                if let reason = summary.unscoreableReason(on: environment) {
                    // The consequence, then the reason. "Not sealed" on its own tells a trainee nothing about
                    // what it means for them.
                    Label("Cannot be scored — \(reason.lowercased())", systemImage: "exclamationmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 0)

            // Two separate buttons rather than a tappable row plus an accessory: sharing a colleague's assessment
            // by mis-tapping a row is not a mistake worth allowing.
            ShareLink(item: logURL) {
                Image(systemName: "square.and.arrow.up")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)

            Button(action: onPlay) {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        var parts = [Self.duration(summary.tickCount)]
        if let forkTick = summary.forkTick {
            parts.append("branched at \(Self.duration(forkTick))")
        }
        parts.append(summary.createdAt.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }

    private static func duration(_ seconds: Int) -> String {
        seconds >= 60 ? "\(seconds / 60) min \(seconds % 60) s" : "\(seconds) s"
    }
}
