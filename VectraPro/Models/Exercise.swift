//
//  Exercise.swift
//  VectraPro
//
//  Model describing a card shown on the home screen and where it routes.
//

import Foundation

/// Destinations reachable from the home screen.
enum HomeRoute: Hashable {
    case map
}

struct Exercise: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let subtitle: String
    let systemImage: String
    let route: HomeRoute
}
