//
//  ReplayBrowserView.swift
//  VectraPro
//
//  The recordings a trainee can replay, and the branches that came out of them.
//
//  Reads the catalogue, which is why it can list two hundred sessions without opening one: everything shown
//  here — duration, class, state, whether it can be scored — is a row, not a recording.
//
//  Styling follows the app's popup design language (navy card + accent border, MenuCard family) rather than a
//  stock list, and each row carries Logs (open the replay at its timeline), Play, Share and Delete. Delete
//  goes through SessionCoordinator → SessionManager.delete (files + catalogue row) behind a destructive alert.
//

import SwiftUI
import ATCReplayKit

struct ReplayBrowserView: View {

    let coordinator: SessionCoordinator

    /// Show only this exercise's recordings (the browser opens from an exercise card).
    var exerciseName: String?

    /// Play/open the recording as a replay.
    let onSelect: (SessionID) -> Void

    /// Told after a successful delete, so a parent can drop any stale replay reference to that id.
    var onDeleted: (SessionID) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss

    @State private var rows: [(summary: SessionSummary, depth: Int)] = []
    @State private var failure: String?
    @State private var pendingDelete: SessionSummary?
    @State private var deleteError: String?

    /// The recording whose log is being read in place, if any. When set, the popup shows that recording's
    /// timeline instead of the list — the logs stay on this screen rather than opening the radar.
    @State private var loggingSession: SessionSummary?

    private let environment = RecordingEnvironment.current()
    private let panelBG = Color(red: 0.06, green: 0.10, blue: 0.18).opacity(0.97)
    private let accent = Color(red: 0.32, green: 0.56, blue: 0.95)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.12))
            content
        }
        .background(panelBG.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task { load() }
        .alert("Delete recording?",
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) { if let s = pendingDelete { delete(s) } }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("“\(name(pendingDelete))” and its recorded events will be permanently removed. This cannot be undone.")
        }
        .alert("Couldn't delete recording",
               isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: { Text(deleteError ?? "") }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let logging = loggingSession {
                // Logs mode: a back affordance returns to the list; the title names the recording.
                Button { loggingSession = nil } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                        .frame(width: 34, height: 34).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text(logging.label.isEmpty ? "Replay Log" : logging.label)
                    .font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                    .lineLimit(1)
            } else {
                Image(systemName: "record.circle")
                    .font(.system(size: 15)).foregroundStyle(.white.opacity(0.85))
                Text(exerciseName ?? "Replay Recordings")
                    .font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                    .frame(width: 34, height: 34).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        if let logging = loggingSession {
            // The recording's log, read through the same manager the row was listed from, in place.
            ReplayTimelineView(sessionID: logging.id, sessions: coordinator.sessions)
                .id(logging.id)   // a distinct recording gets a fresh model + load
        } else if let failure {
            centered("Could not read recordings", failure, "exclamationmark.triangle")
        } else if rows.isEmpty {
            centered("No recordings yet", "Fly an exercise and it will appear here.", "record.circle")
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows, id: \.summary.id) { row in
                        SessionRow(summary: row.summary,
                                   depth: row.depth,
                                   environment: environment,
                                   logURL: coordinator.sessions.eventLogURL(for: row.summary.id),
                                   onPlay: { onSelect(row.summary.id); dismiss() },
                                   onLogs: { loggingSession = row.summary },
                                   onDelete: { pendingDelete = row.summary })
                        Divider().overlay(.white.opacity(0.12))
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func centered(_ title: String, _ subtitle: String, _ symbol: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.white.opacity(0.4))
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity).padding(24)
    }

    private func name(_ s: SessionSummary?) -> String {
        guard let s else { return "Recording" }
        return s.label.isEmpty ? "Exercise" : s.label
    }

    /// Roots first, each followed by its descendants.
    private func load() {
        do {
            var all = try coordinator.sessions.catalogue.allSessions()
            if let exerciseName { all = all.filter { $0.exerciseName == exerciseName } }
            let present = Set(all.map(\.id))
            let byParent = Dictionary(grouping: all.filter { $0.parentID != nil }) { $0.parentID! }
            func walk(_ summary: SessionSummary, depth: Int) -> [(SessionSummary, Int)] {
                [(summary, depth)] + (byParent[summary.id] ?? []).flatMap { walk($0, depth: depth + 1) }
            }
            rows = all.filter { $0.parentID == nil || !present.contains($0.parentID!) }
                .flatMap { walk($0, depth: 0) }
            failure = nil
        } catch {
            failure = "\(error)"
        }
    }

    /// Delete through the existing path (files + catalogue row), then refresh and tell the parent so it can
    /// drop any replay reference to the removed session. A session that is actively recording refuses to
    /// delete (SessionManager.delete throws) — surfaced rather than silently ignored.
    private func delete(_ summary: SessionSummary) {
        let id = summary.id
        pendingDelete = nil
        do {
            try coordinator.delete(id)
            load()
            onDeleted(id)
        } catch {
            deleteError = "\(error)"
        }
    }
}

/// One recording, as a card row.
struct SessionRow: View {

    let summary: SessionSummary
    let depth: Int
    let environment: RecordingEnvironment
    let logURL: URL
    let onPlay: () -> Void
    let onLogs: () -> Void
    let onDelete: () -> Void

    private let accent = Color(red: 0.32, green: 0.56, blue: 0.95)

    var body: some View {
        HStack(spacing: 10) {
            if depth > 0 {
                HStack(spacing: 0) {
                    ForEach(0..<depth, id: \.self) { _ in
                        Rectangle().fill(.white.opacity(0.15)).frame(width: 1).frame(width: 22, alignment: .leading)
                    }
                }
                .frame(height: 40)
                Image(systemName: "arrow.turn.down.right").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(summary.label.isEmpty ? "Exercise" : summary.label)
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    if summary.sessionClass == .assessment {
                        Text("ASSESSMENT")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.orange.opacity(0.22), in: Capsule()).foregroundStyle(.orange)
                    }
                }
                Text(detail).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                if let reason = summary.unscoreableReason(on: environment) {
                    Label("Cannot be scored — \(reason.lowercased())", systemImage: "exclamationmark.circle")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 8)

            actionButton("list.bullet.rectangle", action: onLogs)          // Logs / timeline
            actionButton("play.circle.fill", action: onPlay)               // Play
            ShareLink(item: logURL) {                                      // Share
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 17)).foregroundStyle(.white.opacity(0.85))
                    .frame(width: 40, height: 40).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            actionButton("trash", tint: .red.opacity(0.9), action: onDelete)  // Delete
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
    }

    private func actionButton(_ systemName: String, tint: Color = .white.opacity(0.85),
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18)).foregroundStyle(tint)
                .frame(width: 40, height: 40).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var detail: String {
        var parts = [Self.duration(summary.tickCount)]
        if let forkTick = summary.forkTick { parts.append("branched at \(Self.duration(forkTick))") }
        parts.append(summary.createdAt.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }

    private static func duration(_ seconds: Int) -> String {
        seconds >= 60 ? "\(seconds / 60) min \(seconds % 60) s" : "\(seconds) s"
    }
}
