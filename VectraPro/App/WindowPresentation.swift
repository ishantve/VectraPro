//
//  WindowPresentation.swift
//  VectraPro
//

import Combine

final class WindowPresentation: ObservableObject {
    static let shared = WindowPresentation()
    private init() {}

    /// True while the content is detached into an external / separate window.
    @Published var isRadarOpen = false
}
