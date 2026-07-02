//
//  HoldingHangarPanel.swift
//  VectraPro
//
//  Hangar for holding patterns: a column of tabs (H1, H2, … — one per holding
//  pattern from the exercise) and, beside the selected tab, the list of
//  aircraft holding there. Each card shows callsign / FL and runway / speed.
//

import SwiftUI

struct HoldingHangarPanel: View {

    /// Tab labels, one per holding pattern (e.g. ["H1", "H2", "H3"]).
    let tabs: [String]
    /// Aircraft for each holding pattern, parallel to `tabs`.
    let aircraftByHolding: [[Aircraft]]

    @State private var selected = 0

    private let cardBlue = LinearGradient(
        colors: [Color(red: 0.16, green: 0.28, blue: 0.50),
                 Color(red: 0.09, green: 0.18, blue: 0.36)],
        startPoint: .top, endPoint: .bottom
    )
    private let accent = Color(red: 0.24, green: 0.50, blue: 0.95)

    private var list: [Aircraft] {
        aircraftByHolding.indices.contains(selected) ? aircraftByHolding[selected] : []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Holding Pattern")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)

            if tabs.isEmpty {
                Text("No holding patterns")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.vertical, 8)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    tabColumn
                    listColumn
                }
            }
        }
        .padding(10)
        .frame(width: 250)
        .background(Color(red: 13/255, green: 31/255, blue: 61/255).opacity(0.95),
                    in: RoundedRectangle(cornerRadius: 12))   // navy blue #0D1F3D
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private var tabColumn: some View {
        VStack(spacing: 8) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { index, label in
                Button {
                    selected = index
                } label: {
                    Text(label)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .frame(width: 64)
                        .frame(minHeight: 46)
                        .padding(.horizontal, 4)
                        .background(selected == index ? AnyShapeStyle(accent) : AnyShapeStyle(Color.white.opacity(0.08)),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(.white.opacity(selected == index ? 0.4 : 0.15), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var listColumn: some View {
        Group {
            if list.isEmpty {
                Text("No aircraft")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(list) { ac in
                            card(ac)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func card(_ ac: Aircraft) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ac.callsign).font(.system(size: 15, weight: .bold))
                Text("FL \(ac.flightLevel)").font(.system(size: 14, weight: .semibold))
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(ac.assignedRunway ?? "—").font(.system(size: 15, weight: .bold))
                Text("\(Int(ac.speedKnots))KTS").font(.system(size: 14, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(cardBlue, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(accent.opacity(0.6), lineWidth: 1))
    }
}
