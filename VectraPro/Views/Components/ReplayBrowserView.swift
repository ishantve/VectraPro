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
                        Button { onSelect(row.summary.id); dismiss() } label: {
                            SessionRow(summary: row.summary, depth: row.depth, environment: environment)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Recordings")
            .toolbar { Button("Done") { dismiss() } }
        }
        .task { load() }
    }

    /// Roots first, each followed by its descendants — so a branch reads as belonging to what it came from.
    private func load() {
        do {
            let all = try coordinator.sessions.catalogue.allSessions()
            let byParent = Dictionary(grouping: all.filter { $0.parentID != nil }) { $0.parentID! }

            func walk(_ summary: SessionSummary, depth: Int) -> [(SessionSummary, Int)] {
                [(summary, depth)] + (byParent[summary.id] ?? []).flatMap { walk($0, depth: depth + 1) }
            }
            rows = all.filter { $0.parentID == nil }.flatMap { walk($0, depth: 0) }
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
            Image(systemName: "play.circle").foregroundStyle(.tint)
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
