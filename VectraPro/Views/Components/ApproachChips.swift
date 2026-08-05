//
//  ApproachChips.swift
//  VectraPro
//
//  The row of runway approach toggles.
//
//  Lifted out of MapScreen unchanged. Takes the approaches and two closures rather
//  than the view model, so it has nothing to know about where the list came from.
//

import SwiftUI

struct ApproachChips: View {

    let approaches: [Approach]
    let isEnabled: (ApproachID) -> Bool
    let toggle: (ApproachID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(approaches) { approach in
                    chip(for: approach)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func chip(for approach: Approach) -> some View {
        let on = isEnabled(approach.id)

        return Button(approach.designator) {
            toggle(approach.id)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(on ? Color.green : Color.white.opacity(0.15), in: Capsule())
        .foregroundStyle(on ? .black : .white)
    }
}
