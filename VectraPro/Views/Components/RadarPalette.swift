//
//  RadarPalette.swift
//  VectraPro
//
//  The radar chrome's two colours, in one place.
//
//  They were private to MapScreen and used by every button style on the screen. With
//  those styles moving into their own files the colours had to be either shared or
//  copied, and copied is how two shades of the same blue end up in a codebase.
//

import SwiftUI

enum RadarPalette {

    /// Panel and button fill — #002444 at half strength.
    static let controlFill = Color(red: 0 / 255, green: 36 / 255, blue: 68 / 255).opacity(0.5)

    /// Hairline around panels and buttons — #6EDCFF.
    static let controlBorder = Color(red: 110 / 255, green: 220 / 255, blue: 255 / 255)

    /// Fill of a button whose menu is open.
    static let controlSelected = Color(red: 0.20, green: 0.45, blue: 0.95)
}
