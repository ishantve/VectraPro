//
//  ExerciseService.swift
//  VectraPro
//
//  Fetches the full configuration for the exercise the user started
//  (GET /atc?exerciseId=…) and returns it to the caller, which hands it to the
//  radar (MapViewModel.applyExercise).
//

import Foundation
import NetworkKit

@MainActor
final class ExerciseService {

    static let shared = ExerciseService()

    /// Networking client — injected (defaults to the shared instance).
    private let api: APIManager
    private init(api: APIManager? = nil) {
        self.api = api ?? .shared
    }

    /// Fetch the exercise detail. Call on START, before opening the radar.
    ///
    /// Returns the payload alongside the decoded value. A recording embeds the exercise configuration as the
    /// **bytes the backend actually served** — not an exercise id and not a re-encoding of a decoded copy —
    /// because a replay that fetched its configuration again would be replaying a different world if the
    /// backend had since changed a fix, with no error anywhere.
    func loadDetail(exerciseID: String) async throws -> (detail: ExerciseDetail, payload: Data) {
        let (response, payload): (ExerciseDetailResponse, Data) = try await api.requestWithPayload(
            Endpoint.exerciseDetail(exerciseID: exerciseID)
        )
        guard let detail = response.record else {
            throw APIError.invalidResponse
        }
        return (detail, payload)
    }
}
