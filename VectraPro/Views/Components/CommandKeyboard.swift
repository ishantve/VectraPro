//
//  CommandKeyboard.swift
//  VectraPro
//
//  Collapsible multi-level ATC command keypad at the radar's bottom-right.
//   • Level 1: the 2-column command grid.
//   • Level 2: a numeric keypad (digits + Back) shown when a parameterised
//     command (e.g. ↑SPD*) is tapped, so the value can be entered.
//  A chevron handle slides the whole panel in / out.
//

import SwiftUI

struct CommandKeyboard: View {

    /// Tapped a command that applies immediately (no value needed).
    var onCommand: (String) -> Void = { _ in }
    /// True if the command needs a numeric value (opens level 2).
    var requiresValue: (String) -> Bool = { _ in false }
    /// Full command sentence (with "xxx") used for the live preview.
    var promptFor: (String) -> String = { $0 }
    /// A single-value command confirmed with its entered number.
    var onValue: (String, Int) -> Void = { _, _ in }
    /// A two-value (block) command confirmed with both numbers.
    var onBlock: (String, Int, Int) -> Void = { _, _, _ in }
    /// How many numbers the command needs (2 = block altitude).
    var valueCount: (String) -> Int = { _ in 1 }
    /// Live command-sentence preview (xxx replaced) shown in the mic field.
    var onPreview: (String) -> Void = { _ in }
    /// Left the numeric level — applied (commit) or cancelled (clear).
    var onDismissPreview: (Bool) -> Void = { _ in }
    /// Optional mic button shown to the left of the toggle arrow.
    var micViewModel: SpeechViewModel? = nil

    @State private var expanded = true
    /// Non-nil when the numeric level is open for this command.
    @State private var activeCommand: String?
    @State private var entry = ""
    /// First value of a two-value (block) command, once confirmed with NEXT.
    @State private var firstValue: Int?

    private let maxDigits = 3

    // MARK: Key model

    private enum Style {
        case amber, green, magenta, orange, indigo, olive, teal, blue, purple

        var gradient: LinearGradient {
            let colors: [Color]
            switch self {
            case .amber:   colors = [Color(hex: 0xF8CB5E), Color(hex: 0xE07E22)]
            case .green:   colors = [Color(hex: 0x7BD06A), Color(hex: 0x349235)]
            case .magenta: colors = [Color(hex: 0xC85BE0), Color(hex: 0x8E25B6)]
            case .orange:  colors = [Color(hex: 0xFAA94E), Color(hex: 0xE2611E)]
            case .indigo:  colors = [Color(hex: 0x9A8CF2), Color(hex: 0x5046CC)]
            case .olive:   colors = [Color(hex: 0xDCD85A), Color(hex: 0x9C9C20)]
            case .teal:    colors = [Color(hex: 0x77D9B4), Color(hex: 0x33A487)]
            case .blue:    colors = [Color(hex: 0x57A6F2), Color(hex: 0x3B86E0)]
            case .purple:  colors = [Color(hex: 0x9A6BF2), Color(hex: 0x5E32C8)]
            }
            return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private struct Key: Identifiable {
        let id: String
        let title: String
        let style: Style
        init(_ title: String, _ style: Style) {
            self.id = title
            self.title = title
            self.style = style
        }
    }

    private let keys: [Key] = [
        Key("ILOC Rwy*", .amber),  Key("C/T Rwy*", .green),
        Key("GO ARD", .magenta),   Key("HLD", .orange),
        Key("H/O", .indigo),       Key("DIR", .olive),
        Key("TLH", .teal),         Key("TRH", .teal),
        Key("T*DL", .teal),        Key("T*DR", .teal),
        Key("FH", .teal),          Key("FPH", .teal),
        Key("↑SPD*", .blue),       Key("↓SPD*", .blue),
        Key("SPD≥*", .blue),       Key("SPD≤*", .blue),
        Key("SPD*", .blue),        Key("C/M*", .purple),
        Key("D/M*", .purple),      Key("MBLK*-*", .purple)
    ]

    private let columns = [
        GridItem(.fixed(100), spacing: 8),
        GridItem(.fixed(100), spacing: 8)
    ]

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Mic button sits just left of the toggle arrow
            if let mic = micViewModel {
                PushToTalkMicButton(viewModel: mic)
            }
            toggle
            if expanded {
                Group {
                    if let command = activeCommand {
                        numericLevel(command)
                    } else {
                        grid
                    }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    // MARK: Toggle handle

    private var toggle: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                expanded.toggle()
            }
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

    // MARK: Level 1 — command grid

    private var grid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(keys) { key in
                    Button {
                        tapKey(key.title)
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
            .padding(4)
        }
        .frame(width: 216, height: 560)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func tapKey(_ title: String) {
        if requiresValue(title) {
            entry = ""
            firstValue = nil
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                activeCommand = title
            }
            onPreview(previewText(title))   // show the command in the mic field
        } else {
            onCommand(title)
        }
    }

    // MARK: Level 2 — numeric keypad

    private let digitColumns = [
        GridItem(.fixed(100), spacing: 8),
        GridItem(.fixed(100), spacing: 8)
    ]
    private let digits = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]

    private func numericLevel(_ command: String) -> some View {
        VStack(spacing: 8) {
            LazyVGrid(columns: digitColumns, spacing: 8) {
                ForEach(digits, id: \.self) { digit in
                    Button { tapDigit(digit) } label: {
                        Text(digit)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 100, height: 72)
                            .background(numericFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color(hex: 0x4C82BE), lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }

            backButton
            actionButtons(command)
        }
        .padding(4)
        .frame(width: 216)
    }

    private var numericFill: LinearGradient {
        LinearGradient(colors: [Color(hex: 0x16314F), Color(hex: 0x0A1626)],
                       startPoint: .top, endPoint: .bottom)
    }

    private var backButton: some View {
        Button {
            // Cancel: clear the input field and return to the command grid.
            onDismissPreview(false)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                activeCommand = nil
            }
            entry = ""
            firstValue = nil
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left").font(.system(size: 18, weight: .bold))
                Text("Back").font(.system(size: 20, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Style.blue.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// DEL (clear input) and ENT/NEXT (process command) — enabled only with a value.
    private func actionButtons(_ command: String) -> some View {
        let hasValue = !entry.isEmpty
        // For a two-value (block) command, the first ENT becomes NEXT.
        let isFirstOfBlock = valueCount(command) == 2 && firstValue == nil
        let confirmTitle = isFirstOfBlock ? "NEXT" : "ENT"
        return HStack(spacing: 8) {
            // DEL — clears the current input; both buttons then disable.
            Button {
                entry = ""
                onPreview(previewText(command))
            } label: {
                actionLabel("DEL", gradient: redGradient, enabled: hasValue)
            }
            .buttonStyle(.plain)
            .disabled(!hasValue)

            // ENT / NEXT — advance to the second value, or process the command.
            Button {
                confirm(command, advanceOnly: isFirstOfBlock)
            } label: {
                actionLabel(confirmTitle, gradient: greenGradient, enabled: hasValue)
            }
            .buttonStyle(.plain)
            .disabled(!hasValue)
        }
    }

    private func confirm(_ command: String, advanceOnly: Bool) {
        guard let value = Int(entry), value > 0 else { return }

        if advanceOnly {
            // Block: lock the first FL, move on to the second.
            firstValue = value
            entry = ""
            onPreview(previewText(command))
            return
        }

        if valueCount(command) == 2, let low = firstValue {
            onBlock(command, low, value)
        } else {
            onValue(command, value)
        }
        onDismissPreview(true)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            activeCommand = nil
        }
        entry = ""
        firstValue = nil
    }

    private func actionLabel(_ title: String, gradient: LinearGradient, enabled: Bool) -> some View {
        Text(title)
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.3), lineWidth: 1))
            .opacity(enabled ? 1 : 0.4)
    }

    private var redGradient: LinearGradient {
        LinearGradient(colors: [Color(hex: 0xE96054), Color(hex: 0xD0392D)],
                       startPoint: .top, endPoint: .bottom)
    }
    private var greenGradient: LinearGradient {
        LinearGradient(colors: [Color(hex: 0x63C97C), Color(hex: 0x3E9E55)],
                       startPoint: .top, endPoint: .bottom)
    }

    private func tapDigit(_ digit: String) {
        guard entry.count < maxDigits else { return }
        // Keep digits exactly as typed so headings like 090 / 030 are preserved.
        entry += digit
        if let command = activeCommand { onPreview(previewText(command)) }
    }

    /// The command sentence with "xxx" replaced by the entered value(s).
    private func previewText(_ command: String) -> String {
        var text = promptFor(command)
        let current = entry.isEmpty ? "___" : entry

        if valueCount(command) == 2 {
            // First "xxx" = the (locked) low FL, second = the current entry.
            let low = firstValue.map(String.init) ?? (firstValue == nil ? current : "___")
            let high = firstValue == nil ? "___" : current
            if let r = text.range(of: "xxx") { text.replaceSubrange(r, with: low) }
            if let r = text.range(of: "xxx") { text.replaceSubrange(r, with: high) }
        } else {
            text = text.replacingOccurrences(of: "xxx", with: current)
        }
        return text
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

#Preview {
    ZStack {
        Color.black
        CommandKeyboard(
            requiresValue: { $0.contains("SPD") },
            promptFor: { _ in "Maintain xxx knots" }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding()
    }
}
