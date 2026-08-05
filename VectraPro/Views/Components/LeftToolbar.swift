//
//  LeftToolbar.swift
//  VectraPro
//
//  The column of tool buttons down the left of the radar.
//
//  Lifted out of MapScreen unchanged. It reads which menu is open and reports taps;
//  the menus themselves, and where they are positioned, stay with the screen that
//  owns that layout.
//
//  `LeftMenu` came out with it. It was nested in MapScreen, but it is what the screen
//  and the toolbar agree on, so it belongs to neither.
//

import SwiftUI

/// The left-hand tool menus, in the order they appear.
enum LeftMenu {
    case operations, comms, reference, display, insert, collab
}

struct LeftToolbar: View {

    let openMenu: LeftMenu?
    let toggle: (LeftMenu) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 10) {
                button("building.2.fill", .operations)                      // Operations
                button("antenna.radiowaves.left.and.right", .comms)         // Communications
                button("book.fill", .reference)                             // Reference
                button("list.bullet.rectangle.portrait.fill", .display)     // Display layers
            }

            instructorModeLabel

            VStack(spacing: 10) {
                button("rectangle.stack.badge.plus", .insert)               // Insert
                button("doc.text.fill", .collab)                            // ATC Collaboration Hub
            }
        }
    }

    private var instructorModeLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "flag.fill")
            Text("Instructor Mode")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white.opacity(0.9))
        .fixedSize()
        // Keep the column as wide as the buttons (48) with a fixed height so
        // button positions are deterministic; let the label overflow right.
        .frame(width: 48, height: 20, alignment: .leading)
    }

    private func button(_ systemName: String, _ menu: LeftMenu) -> some View {
        ToolButton(systemName: systemName, isOn: openMenu == menu) { toggle(menu) }
    }
}

/// One square radar-chrome button. Selected state fills the button, which is how the
/// left column shows that its menu is open.
struct ToolButton: View {

    let systemName: String
    var isOn: Bool = false
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 48, height: 45)   // same as the top layer buttons
                .background(isOn ? RadarPalette.controlSelected : RadarPalette.controlFill,
                            in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(RadarPalette.controlBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}


/// The same square, but selection shows in the border rather than the fill — the top
/// row marks a mode that is on, not a panel that is open. Kept a separate style rather
/// than a parameter on `ToolButton`, because the two say different things.
struct TopActionButton: View {

    let systemName: String
    var isOn: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 48, height: 45)
                .background(RadarPalette.controlFill, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(isOn ? Color.green : RadarPalette.controlBorder,
                            lineWidth: isOn ? 2 : 1))
        }
        .buttonStyle(.plain)
    }
}
