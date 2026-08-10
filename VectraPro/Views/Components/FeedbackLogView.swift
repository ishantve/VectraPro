//
//  FeedbackLogView.swift
//  VectraPro
//
//  The rolling list of what the pilot said back, and what was refused.
//
//  Lifted out of MapScreen unchanged. It reads one published list and nothing else,
//  so it had no reason to sit inside a nine-hundred-line view.
//

import SwiftUI

struct FeedbackLogView: View {

    @ObservedObject var feedbackManager: CommandFeedbackManager

    /// Green for a readback, red for a refusal — the only two things spoken.
    private static let accepted = Color(red: 0.2, green: 1.0, blue: 0.4)
    private static let rejected = Color(red: 1.0, green: 0.35, blue: 0.35)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(feedbackManager.feedbackLog) { entry in
                row(for: entry)
            }
        }
        .frame(maxWidth: 280, alignment: .leading)
        .animation(.easeInOut(duration: 0.25), value: feedbackManager.feedbackLog.map(\.id))
    }

    private func row(for entry: FeedbackEntry) -> some View {
        let tint = entry.isError ? Self.rejected : Self.accepted

        return HStack(spacing: 6) {
            Image(systemName: entry.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(entry.text)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(tint.opacity(entry.isError ? 0.4 : 0.3), lineWidth: 1)
        )
    }
}
