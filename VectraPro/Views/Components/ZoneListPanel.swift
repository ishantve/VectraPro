//
//  ZoneListPanel.swift
//  VectraPro
//
//  List of the exercise's airspace zones — a colour dot (matching the plotted
//  zone) and the zone name. Shown under the top-right Zone button.
//

import SwiftUI

struct ZoneListPanel: View {

    let zones: [ExerciseDetail.Zone]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Zone")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)

            if zones.isEmpty {
                Text("No zones")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.vertical, 8)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(Array(zones.enumerated()), id: \.offset) { _, zone in
                            row(zone)
                            Divider().overlay(.white.opacity(0.12))
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .padding(10)
        .frame(width: 180)
        .background(Color(red: 13/255, green: 31/255, blue: 61/255).opacity(0.95),
                    in: RoundedRectangle(cornerRadius: 12))   // navy blue #0D1F3D
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private func row(_ zone: ExerciseDetail.Zone) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(uiColor: ZoneRenderer.color(for: zone)))
                .frame(width: 12, height: 12)
            Text(zone.zoneName ?? "—")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }
}
