//
//  MenuCard.swift
//  VectraPro
//
//  The popup card behind every left-tool menu, and the three row styles that go in it.
//
//  Lifted out of MapScreen unchanged. All four are chrome — they take what to draw and
//  report taps. What is *in* each menu, and the state a tap changes, stays with the
//  screen that owns it; extracting that too would mean handing bindings to a view whose
//  only job is to draw rows.
//

import SwiftUI

/// A card sized to its rows and capped at `maxHeight`, scrolling when taller.
///
/// Height is computed from the row count rather than left to the layout system, so the
/// card hugs its content predictably whichever menu is open.
struct MenuCard<Content: View>: View {

    let width: CGFloat
    let maxHeight: CGFloat
    let title: String?
    let rows: Int
    @ViewBuilder let content: () -> Content

    private static var rowHeight: CGFloat { 48 }

    var body: some View {
        let titleHeight: CGFloat = title != nil ? 50 : 0
        let rowsHeight = 12 + CGFloat(rows) * Self.rowHeight
        // The header stays fixed; only the rows scroll, capped to fit maxHeight.
        let scrollHeight = min(rowsHeight, max(80, maxHeight - titleHeight))

        return VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) { content() }
                    .padding(.vertical, 6)
            }
            .frame(height: scrollHeight)
        }
        .frame(width: width)
        .background(Color(red: 0.06, green: 0.10, blue: 0.18).opacity(0.97),
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(Color(red: 0.32, green: 0.56, blue: 0.95).opacity(0.7), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
    }
}

/// The hairline between two rows.
struct MenuDivider: View {
    var body: some View {
        Divider().overlay(.white.opacity(0.12))
    }
}

// MARK: - Rows

/// Icon and label that does something when tapped.
struct MenuActionRow: View {

    let systemName: String
    let title: String
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemName)
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A row that is either on or off, shown by a tick and an orange tint. Tapping the
/// whole row is what switches it, so the hit area is the row rather than a control.
struct MenuToggleRow: View {

    let systemName: String
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemName)
                    .font(.system(size: 18))
                    .foregroundStyle(isOn ? Color.orange : .white)
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(isOn ? Color.orange : .white)
                Spacer(minLength: 0)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isOn ? Color.orange : .white.opacity(0.4))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A map layer with a switch. Distinct from `MenuToggleRow`: this one carries a real
/// control, so the switch is what is tapped, not the row.
struct LayerToggleRow: View {

    let layer: RadarDisplayLayer
    let isOn: Bool
    let setOn: (Bool) -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: layer.icon)
                .font(.system(size: 18))
                .foregroundStyle(.white)
                .frame(width: 26)
            Text(layer.title)
                .font(.system(size: 16))
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { isOn }, set: setOn))
                .labelsHidden()
                .tint(Color(red: 0.20, green: 0.55, blue: 0.98))
                .scaleEffect(0.8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
