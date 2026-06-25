//
//  HomeViewModel.swift
//  VectraPro
//
//  Provides the list of exercises shown on the home screen.
//

import Combine
import Foundation

final class HomeViewModel: ObservableObject {

    let exercises: [Exercise] = [
        Exercise(
            title: "Guess the heading",
            subtitle: "Estimate the aircraft heading on the radar",
            systemImage: "location.north.line.fill",
            route: .map
        ),
        Exercise(
            title: "Navigate between two fixes",
            subtitle: "Plot a course from one fix to another",
            systemImage: "mappin.and.ellipse",
            route: .map
        ),
    ]
}
