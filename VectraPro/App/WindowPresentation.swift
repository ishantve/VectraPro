//
//  WindowPresentation.swift
//  VectraPro
//

import Foundation
import Combine

final class WindowPresentation: ObservableObject {
    static let shared = WindowPresentation()
    private init() {}

    /// True while the radar window is open (radar detached to its own window).
    @Published var isRadarOpen = false
}
