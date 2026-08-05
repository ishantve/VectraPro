//
//  WorkspacePanel.swift
//  VectraPro
//
//  Bordered container for a panel in the detached workspace, and the icon for a radar
//  layer button.
//
//  Lifted out of MapScreen unchanged. Both are chrome with nothing to decide: what goes
//  in the panel, and which layers are on, stay with the screen that tracks them.
//

import SwiftUI

struct WorkspacePanel<Content: View>: View {

    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.06, green: 0.10, blue: 0.22),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1))
    }
}

/// A radar layer's button face.
///
/// Some assets ship with their own grey fill and cyan border baked in; the rest are
/// plain glyphs that have to be given the same treatment here, which is why the two
/// branches exist at all.
struct RadarLayerIcon: View {

    let layer: RadarLayer
    let tint: Color

    var body: some View {
        if layer.hasBakedStyle {
            Image(layer.asset)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
        } else {
            Image(layer.asset)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .colorMultiply(tint)
                // holdingPattern is a wide glyph — less padding so its height matches
                // the rest.
                .padding(layer == .holdingPattern ? 8 : 13)
                .frame(width: 48, height: 45)
                .background(RadarPalette.controlFill, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(RadarPalette.controlBorder, lineWidth: 1))
        }
    }
}
