//
//  MacroKeyboard.swift
//  VectraPro
//
//  The "Macro Keyboard" shown on the MAIN window while the radar is detached
//  into its own window. Same collapsible chrome as CommandKeyboard, but its
//  keys trigger macros (predefined actions/sequences).
//  NOTE: the key set below is placeholder — final macros TBD.
//

import SwiftUI

struct MacroKeyboard: View {

    /// Tapped a macro key (identified by its title).
    var onMacro: (String) -> Void = { _ in }

    @State private var expanded = true

    // MARK: Key model

    private enum Style {
        case blue, teal, purple, orange

        var gradient: LinearGradient {
            let colors: [Color]
            switch self {
            case .blue:   colors = [Color(red: 0x57/255, green: 0xA6/255, blue: 0xF2/255), Color(red: 0x3B/255, green: 0x86/255, blue: 0xE0/255)]
            case .teal:   colors = [Color(red: 0x77/255, green: 0xD9/255, blue: 0xB4/255), Color(red: 0x33/255, green: 0xA4/255, blue: 0x87/255)]
            case .purple: colors = [Color(red: 0x9A/255, green: 0x6B/255, blue: 0xF2/255), Color(red: 0x5E/255, green: 0x32/255, blue: 0xC8/255)]
            case .orange: colors = [Color(red: 0xFA/255, green: 0xA9/255, blue: 0x4E/255), Color(red: 0xE2/255, green: 0x61/255, blue: 0x1E/255)]
            }
            return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private struct Key: Identifiable {
        let id: String
        let title: String
        let style: Style
        init(_ title: String, _ style: Style) { id = title; self.title = title; self.style = style }
    }

    // Placeholder macros — final set to be defined.
    private let keys: [Key] = [
        Key("Macro 1", .blue),   Key("Macro 2", .teal),
        Key("Macro 3", .purple), Key("Macro 4", .orange),
        Key("Macro 5", .blue),   Key("Macro 6", .teal),
    ]

    private let columns = [
        GridItem(.fixed(100), spacing: 8),
        GridItem(.fixed(100), spacing: 8)
    ]

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            toggle
            if expanded {
                grid
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    private var toggle: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { expanded.toggle() }
        } label: {
            Image(systemName: expanded ? "chevron.right" : "chevron.left")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 56)
                .background(Style.blue.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var grid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 8) {
                Text("MACRO")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 4)

                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(keys) { key in
                        Button {
                            onMacro(key.title)
                        } label: {
                            Text(key.title)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.7)
                                .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                                .frame(width: 100, height: 48)
                                .background(key.style.gradient,
                                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(.white.opacity(0.25), lineWidth: 1))
                                .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(4)
        }
        .frame(width: 216, height: 560)
        .fixedSize(horizontal: true, vertical: false)
    }
}
