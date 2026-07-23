//
//  ExerciseService.swift
//  VectraPro
//
//  Fetches the full configuration for the exercise the user started
//  (GET /atc?exerciseId=…) and returns it to the caller, which hands it to the
//  radar (MapViewModel.applyExercise).
//

import Foundation

@MainActor
final class ExerciseService {

    static let shared = ExerciseService()

    /// Networking client — injected (defaults to the shared instance).
    private let api: APIManager
    private init(api: APIManager = .shared) {
        self.api = api
    }

    /// Fetch the exercise detail. Call on START, before opening the radar.
    func loadDetail(exerciseID: String) async throws -> ExerciseDetail {
        let response: ExerciseDetailResponse = try await api.request(
            .exerciseDetail(exerciseID: exerciseID)
        )
        guard let detail = response.record else {
            throw APIError.invalidResponse
        }
        return detail
    }
}
