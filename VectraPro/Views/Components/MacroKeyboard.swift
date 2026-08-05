//
//  MacroKeyboard.swift
//  VectraPro
//
//  The "Macro Keyboard" shown on the MAIN window while the radar is detached
//  into its own window. Fills the blank main screen with an 8 × 9 grid of 72
//  macro keys, grouped by category (Airborne / Ground / Vehicle / Instructor).
//

import SwiftUI

struct MacroKeyboard: View, Equatable {

    /// Tapped a macro key (identified by its title).
    var onMacro: (String) -> Void = { _ in }

    // The grid is static, so the view never needs to re-render on a parent
    // update — this keeps unrelated state changes from rebuilding 72 buttons.
    static func == (lhs: MacroKeyboard, rhs: MacroKeyboard) -> Bool { true }

    // MARK: - Key model

    private enum KC {
        case yellow, cyan, cream, teal, green, tan, magenta, coral, pink, white, red, grey
        var bg: Color {
            switch self {
            case .yellow:  return Color(red: 0.95, green: 0.83, blue: 0.30)
            case .cyan:    return Color(red: 0.52, green: 0.83, blue: 0.92)
            case .cream:   return Color(red: 0.96, green: 0.92, blue: 0.80)
            case .teal:    return Color(red: 0.52, green: 0.85, blue: 0.73)
            case .green:   return Color(red: 0.62, green: 0.82, blue: 0.35)
            case .tan:     return Color(red: 0.91, green: 0.78, blue: 0.56)
            case .magenta: return Color(red: 0.91, green: 0.36, blue: 0.78)
            case .coral:   return Color(red: 0.94, green: 0.56, blue: 0.45)
            case .pink:    return Color(red: 0.95, green: 0.83, blue: 0.90)
            case .white:   return Color(red: 0.96, green: 0.96, blue: 0.93)
            case .red:     return Color(red: 0.90, green: 0.30, blue: 0.24)
            case .grey:    return Color(red: 0.80, green: 0.82, blue: 0.83)
            }
        }
    }

    private struct Key: Identifiable {
        let id = UUID()
        let title: String?      // nil = blank filler cell
        let color: KC
        init(_ title: String?, _ color: KC) { self.title = title; self.color = color }
    }

    /// Left-edge category labels, one per row (nil = no label).
    private let rowLabels: [String?] = [
        "Airborne", "Ground", "Vehicle", "Instructor",
        nil, nil, nil, nil, nil
    ]

    /// 9 rows × 8 columns, matching the reference layout.
    private let rows: [[Key]] = [
        [ Key("LFT H230\nILS", .yellow), Key("LFT H290\nILS", .yellow), Key("DALD\n26", .cyan), Key("VOR DME\n26", .cyan), Key(nil, .grey), Key("RNP VIA\nCB702", .cream), Key("RGT H230\nILS", .yellow), Key("RGT H290\nILS", .yellow) ],
        [ Key("RNP VIA\nCB 703", .cream), Key("RNP VIA\nCB 704", .cream), Key("RNP VIA\nCB 705", .cream), Key("RNP VIA\nCB 706", .cream), Key("Stop\nTurn", .green), Key("@FL70\n210 KTS", .cyan), Key("GO\nAround", .teal), Key("Touch\n&Go", .teal) ],
        [ Key("SPEED\n160 KTS", .teal), Key("SPEED\n180 KTS", .teal), Key("SPEED\n210 KTS", .teal), Key("SPEED\n250 KTS", .teal), Key("ORBIT\nL", .white), Key("ORBIT\nR", .white), Key("360\nL", .white), Key("360\nR", .white) ],
        [ Key("C/D Rate\n200'/m", .tan), Key("C/D Rate\n500'/m", .tan), Key("C/D Rate\n900'/m", .tan), Key("C/D Rate\n1400'/m", .tan), Key("C/D Rate\n2000'/m", .tan), Key("C/D Rate\n2500'/m", .tan), Key("HIDE", .cyan), Key("FREEZE", .cyan) ],
        [ Key("SQK C\nON", .cyan), Key("SQK C\nOFF", .cyan), Key("SQK\nSTOP", .teal), Key("SQK\n7700", .magenta), Key("Force\nLand", .coral), Key("Own Nav\nCCB", .green), Key("UNHIDE", .cyan), Key("UNFREEZE", .cyan) ],
        [ Key("HOLD\nNT", .pink), Key("HOLD\nPJ", .pink), Key("HOLD\nBR", .pink), Key("HOLD\nCCB", .pink), Key("HOLD\nCB 705", .pink), Key("HOLD\nCB 706", .pink), Key("via PJ\n—", .cream), Key("109 Tr\nPJ", .cream) ],
        [ Key("DALD\n08", .yellow), Key("VOR DME\n08", .yellow), Key("DALD\n15", .cream), Key("NDB\n15", .cream), Key("DALD\n33", .coral), Key("VOR DME\n33", .coral), Key("DEST/\nVACB", .teal), Key("Fly to\nVACB", .teal) ],
        [ Key("Direct\nBAMUL", .white), Key("Direct\nMANDU", .white), Key("Direct\nDUMAS", .white), Key("Direct\nELBIS", .white), Key("Direct\nMANUR", .white), Key("Direct\nSULEM", .white), Key("via\nCOLAB", .cyan), Key("VANISH", .red) ],
        [ Key("PD\nCB703", .cream), Key("PD\nCB704", .cream), Key("PD\nCB705", .cream), Key("PD\nCB706", .cream), Key("PD TO\nCB 702", .cream), Key(nil, .grey), Key("Commn\nDesc NOW", .yellow), Key(nil, .grey) ],
    ]

    private let textColor = Color(red: 0.42, green: 0.12, blue: 0.12)   // dark maroon
    private let offWhite   = Color(red: 0.94, green: 0.93, blue: 0.90)
    private let gap: CGFloat = 6

    /// Fills the container — keys scale to the panel's width & height.
    var body: some View {
        VStack(spacing: gap) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: gap) {
                    // Left category label (rotated).
                    Text(rowLabels[r] ?? "")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(textColor.opacity(0.7))
                        .fixedSize()
                        .rotationEffect(.degrees(-90))
                        .frame(width: 16)

                    ForEach(rows[r]) { key in
                        keyView(key)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(offWhite, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(.black.opacity(0.15), lineWidth: 1))
    }

    @ViewBuilder
    private func keyView(_ key: Key) -> some View {
        if let title = key.title {
            Button {
                onMacro(title)
            } label: {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(textColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(key.color.bg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(.black.opacity(0.12), lineWidth: 1))
            }
            .buttonStyle(.plain)
        } else {
            // Blank filler — keeps the grid aligned.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(key.color.bg)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

#Preview {
    MacroKeyboard()
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
}
