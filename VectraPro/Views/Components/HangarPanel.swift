//
//  HangarPanel.swift
//  VectraPro
//
//  List of the radar's aircraft for a category (Arrival / Departure / Enroute),
//  shown under the top-right layer buttons. Each row is a blue card with the
//  callsign and its runway / flight level.
//

import SwiftUI
import ATCSimKit

struct HangarPanel: View {

    let title: String
    let aircraft: [Aircraft]

    private let cardBlue = LinearGradient(
        colors: [Color(red: 0.24, green: 0.50, blue: 0.95),
                 Color(red: 0.16, green: 0.40, blue: 0.86)],
        startPoint: .top, endPoint: .bottom
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)

            if aircraft.isEmpty {
                Text("No aircraft")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(aircraft) { ac in
                            row(ac)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(10)
        .frame(width: 180)
        .background(Color(red: 13/255, green: 31/255, blue: 61/255).opacity(0.95),
                    in: RoundedRectangle(cornerRadius: 12))   // navy blue #0D1F3D
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private func row(_ ac: Aircraft) -> some View {
        HStack {
            Text(ac.callsign)
                .font(.system(size: 15, weight: .bold))
            Spacer(minLength: 8)
            Text(ac.assignedRunway ?? "FL\(ac.flightLevel)")
                .font(.system(size: 15, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .background(cardBlue, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.25), lineWidth: 1))
    }
}
