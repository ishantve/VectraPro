//
//  RadarPresentation.swift
//  VectraPro
//
//  Shared flag coordinating where the single radar map is shown. When the map
//  is hosted on the external display (non-M) or in the dragged radar window
//  (M-series), the iPad MapScreen shows controls only.
//

import Combine
import Foundation

final class RadarPresentation: ObservableObject {
    static let shared = RadarPresentation()
    private init() {}

    /// True while the map is shown somewhere other than the iPad MapScreen.
    @Published var isMapDetached = false
}
