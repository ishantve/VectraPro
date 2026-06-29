//
//  APIEndpoint.swift
//  VectraPro
//
//  Single place to define the API base URL and every endpoint.
//
//  • The base URL is NOT hard-coded — it's fetched at launch from the UDC
//    (discovery) API via `APIEnvironment.bootstrap()`, then applied to APIManager.
//  • Add a case to `Endpoint` for each route — give it a `path` and `method`.
//  • Call through APIManager with the endpoint directly:
//
//        // App launch (before any other API call):
//        try await APIEnvironment.bootstrap()
//
//        let flights: [Flight] = try await APIManager.shared.request(.flights)
//        let created: Flight   = try await APIManager.shared.request(.createFlight, body: newFlight)
//        try await APIManager.shared.request(.deleteFlight(id: "AI302"))
//

import Foundation

// MARK: - Environment / base URL (resolved from UDC)

enum APIEnvironment {

    /// The UDC (discovery) endpoint — the one URL known up front. It returns the
    /// base URL the app should run against. Replace with your real UDC URL.
    static let udcURL = "https://udcsimplira.rigilites.net/api/DataManage/764550"

    /// The base URL resolved from UDC. `nil` until `bootstrap()` succeeds.
    private(set) static var baseURL: URL?

    /// Fetch the org config from the UDC API, apply its API URL to the shared
    /// APIManager, and persist the whole config to the local database.
    /// Call once during app launch, before any other API request.
    @discardableResult
    @MainActor
    static func bootstrap() async throws -> URL {
        // UDC returns an array of org configs; we use the first one. It's called
        // with its absolute URL, so it works before a base URL is set.
        let configs: [UDCConfig] = try await APIManager.shared.get(udcURL)
        guard let config = configs.first else {
            throw APIError.invalidResponse
        }
        guard let url = URL(string: config.apiURL) else {
            throw APIError.invalidURL
        }
        baseURL = url
        APIManager.shared.baseURL = url

        // Save the full config locally (last-known config survives relaunch).
        try ConfigStore.shared.save(config)
        return url
    }

    /// Fetch all org configs from UDC, pick the one whose `OrganizationID`
    /// matches the entered value, apply its API URL, and persist it locally.
    /// Throws `APIError.organizationNotFound` when nothing matches.
    @discardableResult
    @MainActor
    static func configure(organizationID: String) async throws -> UDCConfig {
        let configs: [UDCConfig] = try await APIManager.shared.get(udcURL)
        guard let match = configs.first(where: {
            $0.organizationID.caseInsensitiveCompare(organizationID) == .orderedSame
        }) else {
            throw APIError.organizationNotFound
        }
        guard let url = URL(string: match.apiURL) else {
            throw APIError.invalidURL
        }
        baseURL = url
        APIManager.shared.baseURL = url
        try ConfigStore.shared.save(match)
        return match
    }
}

/// One organization config object returned by the UDC discovery API.
/// Keys mirror the UDC JSON. Decoding is defensive — any null or missing field
/// falls back to a sensible default so one odd record can't fail the whole call.
struct UDCConfig: Decodable {
    let id: Int
    let organizationID: String
    let authURL: String
    let apiURL: String
    let analyticsID: Int
    let analyticsURL: String
    let issuerURL: String
    let eramClientSecret: String?
    let eramClientID: String?
    let eramRedirectURL: String?
    let nickname: String
    let basicVectoringClientID: String
    let basicVectoringSecret: String
    let stratagemMobileID: String
    let stratagemMobileSecret: String
    let metricsURL: String
    let chatBotURL: String
    let showIvyIcon: Bool

    enum CodingKeys: String, CodingKey {
        case id                     = "Id"
        case organizationID         = "OrganizationID"
        case authURL                = "AuthURL"
        case apiURL                 = "APIUrl"
        case analyticsID            = "AnalyticsID"
        case analyticsURL           = "analyticsUrl"
        case issuerURL              = "issuerURL"
        case eramClientSecret       = "eramClientSecret"
        case eramClientID           = "eramClientId"
        case eramRedirectURL        = "eramRedirectURL"
        case nickname               = "Nickname"
        case basicVectoringClientID = "BasicVectoringclid"
        case basicVectoringSecret   = "BasicVectroingsecret"
        case stratagemMobileID      = "StratagemMobileID"
        case stratagemMobileSecret  = "StratagemMobileSecret"
        case metricsURL             = "metricsUrl"
        case chatBotURL             = "chatBotUrl"
        case showIvyIcon            = "showIvyIcon"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                     = (try? c.decodeIfPresent(Int.self, forKey: .id)) ?? 0
        organizationID         = (try? c.decodeIfPresent(String.self, forKey: .organizationID)) ?? ""
        authURL                = (try? c.decodeIfPresent(String.self, forKey: .authURL)) ?? ""
        apiURL                 = (try? c.decodeIfPresent(String.self, forKey: .apiURL)) ?? ""
        analyticsID            = (try? c.decodeIfPresent(Int.self, forKey: .analyticsID)) ?? 0
        analyticsURL           = (try? c.decodeIfPresent(String.self, forKey: .analyticsURL)) ?? ""
        issuerURL              = (try? c.decodeIfPresent(String.self, forKey: .issuerURL)) ?? ""
        eramClientSecret       = try? c.decodeIfPresent(String.self, forKey: .eramClientSecret)
        eramClientID           = try? c.decodeIfPresent(String.self, forKey: .eramClientID)
        eramRedirectURL        = try? c.decodeIfPresent(String.self, forKey: .eramRedirectURL)
        nickname               = (try? c.decodeIfPresent(String.self, forKey: .nickname)) ?? ""
        basicVectoringClientID = (try? c.decodeIfPresent(String.self, forKey: .basicVectoringClientID)) ?? ""
        basicVectoringSecret   = (try? c.decodeIfPresent(String.self, forKey: .basicVectoringSecret)) ?? ""
        stratagemMobileID      = (try? c.decodeIfPresent(String.self, forKey: .stratagemMobileID)) ?? ""
        stratagemMobileSecret  = (try? c.decodeIfPresent(String.self, forKey: .stratagemMobileSecret)) ?? ""
        metricsURL             = (try? c.decodeIfPresent(String.self, forKey: .metricsURL)) ?? ""
        chatBotURL             = (try? c.decodeIfPresent(String.self, forKey: .chatBotURL)) ?? ""
        showIvyIcon            = (try? c.decodeIfPresent(Bool.self, forKey: .showIvyIcon)) ?? false
    }
}

// MARK: - Endpoints

/// Every API route lives here. Each case maps to a `path`, an HTTP `method`,
/// and (optionally) query items. Add new routes by adding a case below.
enum Endpoint {
    // Flights — examples; replace with your real routes.
    case flights
    case flight(id: String)
    case createFlight
    case updateFlight(id: String)
    case patchFlight(id: String)
    case deleteFlight(id: String)

    /// Path appended to the base URL.
    var path: String {
        switch self {
        case .flights, .createFlight:
            return "/flights"
        case .flight(let id),
             .updateFlight(let id),
             .patchFlight(let id),
             .deleteFlight(let id):
            return "/flights/\(id)"
        }
    }

    /// HTTP verb for this endpoint.
    var method: HTTPMethod {
        switch self {
        case .flights, .flight:   return .get
        case .createFlight:       return .post
        case .updateFlight:       return .put
        case .patchFlight:        return .patch
        case .deleteFlight:       return .delete
        }
    }

    /// Optional query items for this endpoint (default none).
    var query: [URLQueryItem]? {
        switch self {
        default: return nil
        }
    }
}

// MARK: - APIManager + Endpoint

extension APIManager {

    /// Bodyless request (GET / DELETE) → decoded response.
    func request<Response: Decodable>(
        _ endpoint: Endpoint,
        headers: [String: String] = [:]
    ) async throws -> Response {
        try await request(endpoint.path,
                          method: endpoint.method,
                          query: endpoint.query,
                          headers: headers)
    }

    /// Request with an Encodable body (POST / PUT / PATCH) → decoded response.
    func request<Body: Encodable, Response: Decodable>(
        _ endpoint: Endpoint,
        body: Body,
        headers: [String: String] = [:]
    ) async throws -> Response {
        try await request(endpoint.path,
                          method: endpoint.method,
                          body: body,
                          query: endpoint.query,
                          headers: headers)
    }

    /// Request with an Encodable body, ignoring the response body.
    @discardableResult
    func request<Body: Encodable>(
        _ endpoint: Endpoint,
        body: Body,
        headers: [String: String] = [:]
    ) async throws -> Data {
        try await requestData(endpoint.path,
                              method: endpoint.method,
                              body: body,
                              query: endpoint.query,
                              headers: headers)
    }

    /// Bodyless request, ignoring the response body (e.g. DELETE).
    @discardableResult
    func request(
        _ endpoint: Endpoint,
        headers: [String: String] = [:]
    ) async throws -> Data {
        switch endpoint.method {
        case .delete:
            return try await delete(endpoint.path, query: endpoint.query, headers: headers)
        default:
            let data: Data = try await request(endpoint.path,
                                               method: endpoint.method,
                                               query: endpoint.query,
                                               headers: headers)
            return data
        }
    }
}
