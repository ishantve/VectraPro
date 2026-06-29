//
//  HomeScreen.swift
//  VectraPro
//
//  Root screen listing the available exercises as horizontal cards.
//

import SwiftUI

struct HomeScreen: View {

    @StateObject private var viewModel = HomeViewModel()
    @AppStorage(MapProvider.storageKey) private var providerRaw = MapProvider.mapLibre.rawValue

    private var provider: Binding<MapProvider> {
        Binding(
            get: { MapProvider(rawValue: providerRaw) ?? .mapLibre },
            set: { providerRaw = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {

                mapProviderPicker

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
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                Image("MainMenu")
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
            }
            .navigationTitle("VectraPro")
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .map:
                    MapScreen()
                }
            }
        }
    }

    private var mapProviderPicker: some View {
        HStack(spacing: 12) {
            Text("Map")
                .font(.headline)
                .foregroundStyle(.white)

            Picker("Map", selection: provider) {
                ForEach(MapProvider.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.menu)
            .tint(.green)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }
}

#Preview {
    HomeScreen()
}
