//
//  HomeScreen.swift
//  VectraPro
//
//  Root screen listing the available exercises as horizontal cards.
//

import SwiftUI

struct HomeScreen: View {

    @StateObject private var viewModel = HomeViewModel()

    var body: some View {
        NavigationStack {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(viewModel.exercises) { exercise in
                        NavigationLink(value: exercise.route) {
                            ExerciseCard(exercise: exercise)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(.black)
            .navigationTitle("VectraPro")
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .map:
                    MapScreen()
                }
            }
        }
    }
}

#Preview {
    HomeScreen()
}
