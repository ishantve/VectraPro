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
    @Published private(set) var isLoadingMore = false
    @Published var errorMessage: String?

    private let pageSize = 10
    private var pageNo = 0
    private var total = 0

    // Collaborators — injected (default to the shared instances) so the view
    // model owns no global reaches and can be tested with doubles.
    private let api: APIManager
    private let exerciseService: ExerciseService
    private let radar: MapViewModel

    init(api: APIManager? = nil,
         exerciseService: ExerciseService? = nil,
         radar: MapViewModel? = nil) {
        self.api = api ?? .shared
        self.exerciseService = exerciseService ?? .shared
        self.radar = radar ?? .shared
    }

    /// More pages available to load.
    private var hasMore: Bool { exercises.count < total }

    /// Load the started exercise's config and set up the radar. Throws on
    /// failure so the view can surface the error. (Orchestration lives here,
    /// not in the view.)
    func startExercise(_ exercise: Exercise) async throws {
        let detail = try await exerciseService.loadDetail(exerciseID: exercise.id)
        radar.applyExercise(detail)
    }

    /// Load (or reload) the first page.
    func load() async {
        isLoading = true
        errorMessage = nil
        pageNo = 0
        do {
            let response = try await fetch(page: 0)
            exercises = response.record
            total = response.length
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Load the next page when the user scrolls near the end of the list.
    func loadMoreIfNeeded(currentItem: Exercise) async {
        guard !isLoading, !isLoadingMore, hasMore,
              let index = exercises.firstIndex(of: currentItem),
              index >= exercises.count - 3 else { return }
        await loadMore()
    }

    private func loadMore() async {
        guard !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        let next = pageNo + 1
        do {
            let response = try await fetch(page: next)
            exercises.append(contentsOf: response.record)
            pageNo = next
            total = response.length
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingMore = false
    }

    private func fetch(page: Int) async throws -> ExercisesResponse {
        try await api.request(
            .exercises(pageNo: page, pageSize: pageSize, search: "")
        )
    }
}
