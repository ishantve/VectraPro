//
//  FlightDataPopup.swift
//  VectraPro
//
//  "Selected Flight Data" panel (Operations → Flight Data). Reproduces the
//  reference layout: a title bar, a top grid of the aircraft's values with a
//  coloured left column, and a labelled detail list below. All values come
//  from the selected aircraft; blank/dashed when none is selected.
//

import SwiftUI

struct FlightDataPopup: View {

    let aircraft: Aircraft?
    var onClose: () -> Void = {}

    // Palette (matches the reference).
    private let panelBG = Color(red: 0.42, green: 0.43, blue: 0.40)
    private let titleBG = Color(red: 0.28, green: 0.29, blue: 0.27)
    private let grid    = Color(red: 0.36, green: 0.38, blue: 0.85)
    private let cyan    = Color(red: 0.30, green: 0.85, blue: 0.85)
    private let yellow  = Color(red: 0.96, green: 0.90, blue: 0.25)
    private let mono    = Font.system(size: 14, weight: .semibold, design: .monospaced)

    private let labelW: CGFloat = 116
    private let cellW: CGFloat  = 78
    private let rowH: CGFloat   = 30

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            topGrid
            detailList
        }
        .frame(width: labelW + cellW * 7)   // fit the widest (7-cell) row, no extra
        .background(panelBG)
        .overlay(Rectangle().stroke(.white.opacity(0.3), lineWidth: 1))
    }

    // MARK: - Title bar

    private var titleBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.fill").font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
            Text("Selected Flight Data")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(titleBG)
    }

    // MARK: - Top grid

    /// Each row: coloured label + up to 7 value cells (left-aligned, blue grid).
    private var topGrid: some View {
        VStack(spacing: 0) {
            gridRow(label: "", labelColor: .white, cells: [freq])
            gridRow(label: callsign, labelColor: cyan,
                    cells: [d("1013"), fl, arrow, d("N"), targetFL, d("180"), crate])
            gridRow(label: typeWake, labelColor: .white, cells: ["HDG", hdgH])
            gridRow(label: d("VOTV"), labelColor: yellow,
                    cells: ["ROUTE", route, d("00:00:00"), d("189/58.0"), d("180")])
            gridRow(label: d("VACB"), labelColor: yellow, cells: ["SPEED", speed])
            gridRow(label: squawkAC, labelColor: .white, cells: ["STATUS", squawk, squawk])
        }
    }

    private func gridRow(label: String, labelColor: Color, cells: [String]) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(mono).foregroundStyle(labelColor)
                .lineLimit(1).minimumScaleFactor(0.6)
                .padding(.leading, 8)
                .frame(width: labelW, height: rowH, alignment: .leading)
                .overlay {
                    if !label.isEmpty { Rectangle().stroke(grid, lineWidth: 1) }
                }
            ForEach(Array(cells.enumerated()), id: \.offset) { _, text in
                Text(text)
                    .font(mono).foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .frame(width: cellW, height: rowH)
                    .overlay(Rectangle().stroke(grid, lineWidth: 1))
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Detail list

    private var detailList: some View {
        VStack(alignment: .leading, spacing: 0) {
            detailRow("ROUTE", route)
            detailRow("SID", d("DEFAULT"))
            detailRow("STAR", d("DEFAULT"))
            detailRow("REMARKS", hasAC ? (aircraft?.remarks ?? "") : dash)
            detailRow("A/C STATE", acState)
            detailRow("ROA", roa)
            detailRow("HDG", hdgH)
            detailRow("GS", gs)
            detailRow("TAR", tar)
            detailRow("ASPD", aspd)
            detailRow("CRATE", crate)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(mono).foregroundStyle(yellow)
                .frame(width: labelW, height: 28, alignment: .leading)
                .padding(.leading, 8)
            Text(value)
                .font(mono).foregroundStyle(.white)
                .frame(alignment: .leading)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Derived values

    private let dash = "—"
    private var hasAC: Bool { aircraft != nil }
    private func d(_ value: String) -> String { hasAC ? value : dash }

    private var freq: String     { d("127.900") }
    private var callsign: String { aircraft?.callsign ?? dash }
    private var typeWake: String { aircraft.map { "\($0.aircraftType ?? "—") /M" } ?? dash }
    private var squawkAC: String { aircraft.map { "\($0.squawk)AC" } ?? dash }
    private var squawk: String   { aircraft?.squawk ?? dash }
    private var fl: String       { aircraft.map { "FL\($0.flightLevel)" } ?? dash }
    private var speed: String    { aircraft.map { "\(Int($0.speedKnots))" } ?? dash }
    private var gs: String       { aircraft.map { "\(Int($0.speedKnots))" } ?? dash }
    private var hdgH: String     { aircraft.map { "H" + String(format: "%03d", Int($0.headingDegrees.rounded())) } ?? dash }
    private var tar: String      { aircraft?.targetHeading.map { String(format: "%03d", Int($0.rounded())) } ?? d("0") }
    private var aspd: String     { aircraft.map { "\(Int($0.targetSpeedKnots ?? $0.speedKnots))" } ?? dash }
    private var route: String    { d("DIRECT") }
    private var roa: String      { hasAC ? (aircraft?.assignedRunway ?? "0") : dash }
    private var arrow: String {
        guard let ac = aircraft, let t = ac.targetAltitudeFeet else { return dash }
        if t > ac.altitudeFeet { return "↑" }
        if t < ac.altitudeFeet { return "↓" }
        return dash
    }
    private var targetFL: String {
        guard let ac = aircraft else { return dash }
        if let t = ac.targetAltitudeFeet { return "FL\(Int(t / 100))" }
        return "FL\(ac.flightLevel)"
    }
    private var crate: String {
        guard let ac = aircraft else { return dash }
        guard let t = ac.targetAltitudeFeet, t != ac.altitudeFeet else { return "0" }
        return "\(Int(t - ac.altitudeFeet))"
    }
    private var acState: String {
        guard let ac = aircraft else { return dash }
        if ac.holdingName != nil { return "Hold" }
        if let t = ac.targetAltitudeFeet {
            if t > ac.altitudeFeet { return "Climb" }
            if t < ac.altitudeFeet { return "Descent" }
        }
        return "Own Nav"
    }
}

#Preview {
    FlightDataPopup(aircraft: nil).padding().background(.black)
}
