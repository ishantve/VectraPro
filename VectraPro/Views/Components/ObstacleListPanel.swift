//
//  ObstacleListPanel.swift
//  VectraPro
//
//  List of the exercise's obstacles (API "obstruction") — a type icon, the
//  name, and the elevation in feet. Shown under the top-right Obstacle button.
//

import SwiftUI

struct ObstacleListPanel: View {

    let obstacles: [ExerciseDetail.Obstruction]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Obstacles")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)

            if obstacles.isEmpty {
                Text("No obstacles")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.vertical, 8)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(Array(obstacles.enumerated()), id: \.offset) { _, obstacle in
                            row(obstacle)
                            Divider().overlay(.white.opacity(0.12))
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(10)
        .frame(width: 210)
        .background(Color(red: 13/255, green: 31/255, blue: 61/255).opacity(0.95),
                    in: RoundedRectangle(cornerRadius: 12))   // navy blue #0D1F3D
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private func row(_ obstacle: ExerciseDetail.Obstruction) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: obstacle.obstructionType))
                .font(.system(size: 20))
                .foregroundStyle(.white)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(obstacle.obstructionName ?? "—")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Text(elevationText(obstacle.elevationInFeet))
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.65))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }

    private func elevationText(_ feet: Double?) -> String {
        guard let feet else { return "—" }
        return "\(Int(feet)) feet"
    }

    /// SF Symbol for an obstruction type (Mountain Peak / Building / Tower / …).
    private func icon(for type: String?) -> String {
        switch type?.lowercased() {
        case let t? where t.contains("mountain") || t.contains("peak"): return "mountain.2.fill"
        case let t? where t.contains("building") || t.contains("temple"): return "building.2.fill"
        case let t? where t.contains("tower") || t.contains("mast") || t.contains("antenna"): return "antenna.radiowaves.left.and.right"
        case let t? where t.contains("windmill") || t.contains("turbine"): return "fan.fill"
        case let t? where t.contains("tank"): return "drop.fill"
        default: return "triangle.fill"
        }
    }
}
