//
//  ConfigStore.swift
//  VectraPro
//
//  Owns the SwiftData container and persists the organization config from UDC.
//  Use `ConfigStore.shared.container` as the app's model container so SwiftUI
//  `@Query` views read the same store.
//

import Foundation
import SwiftData

@MainActor
final class ConfigStore {

    static let shared = ConfigStore()

    let container: ModelContainer

    private init() {
        do {
            container = try ModelContainer(for: AirtableConfig.self)
        } catch {
            fatalError("Failed to create the ConfigStore container: \(error)")
        }
    }

    private var context: ModelContext { container.mainContext }

    /// Replace any stored config with the latest one from UDC (single org).
    func save(_ config: UDCConfig) throws {
        try context.delete(model: AirtableConfig.self)
        context.insert(AirtableConfig(from: config))
        try context.save()
    }

    /// The last-known org config, if one was saved.
    func current() -> AirtableConfig? {
        try? context.fetch(FetchDescriptor<AirtableConfig>()).first
    }

    /// The last-known API base URL, if available (for launching before UDC responds).
    var cachedBaseURL: URL? {
        guard let apiURL = current()?.apiURL else { return nil }
        return URL(string: apiURL)
    }
}
