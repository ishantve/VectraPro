//
//  HomeViewModel.swift
//  VectraPro
//
//  Loads the home-screen exercise list from /atc/excercise.
//

import Combine
import Foundation

@MainActor
final class HomeViewModel: ObservableObject {

    @Published private(set) var exercises: [Exercise] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let response: ExercisesResponse = try await APIManager.shared.request(
                .exercises(pageNo: 0, pageSize: 10, search: "")
            )
            exercises = response.record
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
