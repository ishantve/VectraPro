//
//  RadarControls.swift
//  VectraPro
//
//  The two small button clusters over the radar: zoom, and simulation speed.
//
//  Lifted out of MapScreen unchanged. Both are three buttons around one value, and
//  they shared the same chrome by copy — that chrome is now written once.
//

import SwiftUI

/// Black rounded slab the radar's overlay controls sit on.
private struct ControlCluster<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 1, content: content)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.15), lineWidth: 1))
    }
}

private struct ClusterDivider: View {
    var body: some View {
        Divider().frame(height: 44).background(.white.opacity(0.2))
    }
}

// MARK: - Zoom

struct RadarZoomControl: View {

    let zoom: (Double) -> Void

    var body: some View {
        ControlCluster {
            button(systemImage: "minus", delta: -1)
            ClusterDivider()
            button(systemImage: "plus", delta: 1)
        }
    }

    private func button(systemImage: String, delta: Double) -> some View {
        Button {
            zoom(delta)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
        }
    }
}

// MARK: - Simulation speed

struct SimulationSpeedControl: View {

    let speed: Int
    let canSlowDown: Bool
    let canSpeedUp: Bool
    let slowDown: () -> Void
    let speedUp: () -> Void

    var body: some View {
        ControlCluster {
            button(systemImage: "backward.fill", enabled: canSlowDown, action: slowDown)
            ClusterDivider()
            Text("\(speed)X")
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(red: 0.2, green: 1.0, blue: 0.4))
                .frame(width: 52, height: 44)
            ClusterDivider()
            button(systemImage: "forward.fill", enabled: canSpeedUp, action: speedUp)
        }
    }

    private func button(systemImage: String,
                        enabled: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(enabled ? .white : .white.opacity(0.3))
                .frame(width: 44, height: 44)
        }
        .disabled(!enabled)
    }
}
