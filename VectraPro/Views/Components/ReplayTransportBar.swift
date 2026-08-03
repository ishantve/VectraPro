//
//  ReplayTransportBar.swift
//  VectraPro
//
//  The replay transport: scrubber, play/pause, step, speed, and continue.
//
//  ── It holds nothing ───────────────────────────────────────────────────────
//  No `@State` for playing, position or speed. Everything drawn comes from `ReplayTransportState` and every tap
//  becomes a `ReplayCommand`. The one piece of local state is `isDragging`, which is about the finger rather than
//  the replay — while a drag is in progress the scrubber shows where the finger is, and on release it asks the
//  engine to go there. Without that the thumb would snap back to the engine's position on every frame of the drag.
//
//  Being disposable is the point: this file could be deleted and rewritten in UIKit against the same two types.
//

import SwiftUI

struct ReplayTransportBar: View {

    @ObservedObject var clock: ReplayClock
    let transport: ReplayTransport

    /// Called when the trainee continues from here. The view does not fork anything itself — it asks, and whoever
    /// owns the screen decides what to do with a new live session.
    var onContinue: (() -> Void)?

    /// Where the finger is mid-drag. About the gesture, not the replay.
    @State private var isDragging = false
    @State private var draggedProgress: Double = 0

    private var state: ReplayTransportState { transport.state }

    var body: some View {
        VStack(spacing: 10) {
            if !state.isReproducibleHere { validityWarning }
            scrubber
            controls
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(.white.opacity(0.12), lineWidth: 1))
        .opacity(state.isLoaded ? 1 : 0.5)
        .allowsHitTesting(state.isLoaded)
    }

    // MARK: - Validity

    /// Said out loud rather than left to a badge somewhere. A reviewer who does not know a replay is unscoreable
    /// is a reviewer who might score it.
    private var validityWarning: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Recorded on a different architecture — replay is for review only, not scoring.")
                .font(.caption)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.orange)
    }

    // MARK: - Scrubber

    private var scrubber: some View {
        HStack(spacing: 10) {
            Text(Self.clock(state.position))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)

            Slider(value: Binding(
                get: { isDragging ? draggedProgress : state.progress },
                set: { draggedProgress = $0 }
            ), in: 0...1) { editing in
                // Seek on release, not continuously: a seek re-simulates, and doing that on every frame of a drag
                // would do hundreds of them to land in one place.
                isDragging = editing
                if !editing { transport.seek(toProgress: draggedProgress) }
            }
            .disabled(!state.canSeek)
            .tint(.white)

            Text(Self.clock(state.duration))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 14) {
            button("backward.end.fill", enabled: state.isLoaded) { transport.perform(.restart) }

            button(state.canPause ? "pause.fill" : "play.fill",
                   enabled: state.canPause || state.canPlay,
                   prominent: true) {
                transport.perform(state.canPause ? .pause : .play)
            }

            button("forward.frame.fill", enabled: state.isLoaded && !state.isAtEnd) {
                transport.perform(.stepForward)
            }

            speedPicker

            Spacer(minLength: 0)

            Button {
                onContinue?()
            } label: {
                Label("Continue", systemImage: "arrow.triangle.branch")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .disabled(!state.isLoaded)
        }
    }

    /// Offers whatever the engine offers, so a picker cannot drift from what `setSpeed` accepts.
    private var speedPicker: some View {
        Menu {
            ForEach(state.availableSpeeds, id: \.self) { speed in
                Button {
                    transport.perform(.setSpeed(speed))
                } label: {
                    if speed == state.speed { Label(Self.speed(speed), systemImage: "checkmark") }
                    else { Text(Self.speed(speed)) }
                }
            }
        } label: {
            Text(Self.speed(state.speed))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(minWidth: 46)
                .padding(.vertical, 6)
                .background(.white.opacity(0.12), in: Capsule())
        }
    }

    private func button(_ systemName: String,
                        enabled: Bool,
                        prominent: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: prominent ? 20 : 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: prominent ? 40 : 32, height: prominent ? 40 : 32)
                .background(.white.opacity(prominent ? 0.2 : 0.1), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    // MARK: - Formatting
    //
    // Here rather than in `ReplayTransportState`, which returns raw values on purpose: how to write a duration is a
    // presentation decision, and another platform will make it differently.

    private static func clock(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private static func speed(_ speed: Double) -> String {
        speed < 1 ? String(format: "%.2g×", speed) : String(format: "%g×", speed)
    }
}
