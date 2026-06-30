//
//  ExerciseService.swift
//  VectraPro
//
//  Loads and holds the full configuration for the exercise the user started
//  (GET /atc?exerciseId=…). The radar reads `current` to set itself up.
//

import Foundation

@MainActor
final class ExerciseService {

    static let shared = ExerciseService()

    /// The started exercise's full configuration.
    private(set) var current: ExerciseDetail?

    /// Fetch and save the exercise detail. Call on START, before opening the radar.
    @discardableResult
    func loadDetail(exerciseID: String) async throws -> ExerciseDetail {
        let response: ExerciseDetailResponse = try await APIManager.shared.request(
            .exerciseDetail(exerciseID: exerciseID)
        )
        guard let detail = response.record else {
            throw APIError.invalidResponse
        }
        current = detail
        return detail
    }
}
