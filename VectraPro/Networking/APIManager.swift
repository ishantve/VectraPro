//
//  APIManager.swift
//  VectraPro
//
//  Lightweight async/await networking layer over URLSession.
//
//  Supports GET / POST / PUT / PATCH / DELETE with an Encodable body and a
//  Decodable response. Headers are layered: `defaultHeaders` (shared, e.g. an
//  auth token or API key) are merged with the per-request `headers` you pass —
//  per-request values win on a key clash.
//
//  Usage:
//
//      // One-time setup (e.g. in app launch):
//      APIManager.shared.baseURL = URL(string: "https://api.example.com")
//      APIManager.shared.setDefaultHeader("Bearer \(token)", forKey: "Authorization")
//
//      // GET → decoded model
//      let user: User = try await APIManager.shared.get("/users/42")
//
//      // POST with body + a custom header for this call only
//      let created: Aircraft = try await APIManager.shared.post(
//          "/aircraft",
//          body: newAircraft,
//          headers: ["X-Request-ID": uuid]
//      )
//
//      // DELETE with no response body
//      try await APIManager.shared.delete("/aircraft/42")
//

import Foundation

final class APIManager {

    static let shared = APIManager()

    /// Optional base URL. When set, request paths are resolved against it, so
    /// callers can pass relative paths ("/users"). Absolute URLs also work.
    var baseURL: URL?

    /// Headers sent on every request (e.g. Authorization, API keys, Accept).
    /// Per-request headers override these on matching keys.
    private(set) var defaultHeaders: [String: String] = [
        "Accept": "application/json"
    ]

    /// Default timeout applied to requests that don't override it.
    var timeout: TimeInterval = 30

    /// Supplies a valid bearer token before each request (refreshing if needed).
    /// Set by AuthService. Token endpoints bypass this to avoid recursion.
    var tokenProvider: (() async throws -> String?)?

    /// Forces a token refresh and returns the new token. Called when a request
    /// comes back 401 so it can be retried once. Set by AuthService.
    var tokenRefresher: (() async throws -> String?)?

    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(session: URLSession = .shared,
         encoder: JSONEncoder = JSONEncoder(),
         decoder: JSONDecoder = JSONDecoder()) {
        self.session = session
        self.encoder = encoder
        self.decoder = decoder
    }

    // MARK: Header management

    /// Add or replace a default header sent on every request.
    func setDefaultHeader(_ value: String, forKey key: String) {
        defaultHeaders[key] = value
    }

    /// Remove a default header.
    func removeDefaultHeader(forKey key: String) {
        defaultHeaders[key] = nil
    }

    // MARK: Convenience verbs — decoded response

    func get<Response: Decodable>(
        _ path: String,
        query: [URLQueryItem]? = nil,
        headers: [String: String] = [:]
    ) async throws -> Response {
        let data = try await sendData(path, method: .get, bodyData: nil, query: query, headers: headers)
        return try decode(data)
    }

    func post<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        query: [URLQueryItem]? = nil,
        headers: [String: String] = [:]
    ) async throws -> Response {
        let data = try await requestData(path, method: .post, body: body, query: query, headers: headers)
        return try decode(data)
    }

    func put<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        query: [URLQueryItem]? = nil,
        headers: [String: String] = [:]
    ) async throws -> Response {
        let data = try await requestData(path, method: .put, body: body, query: query, headers: headers)
        return try decode(data)
    }

    func patch<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        query: [URLQueryItem]? = nil,
        headers: [String: String] = [:]
    ) async throws -> Response {
        let data = try await requestData(path, method: .patch, body: body, query: query, headers: headers)
        return try decode(data)
    }

    func delete<Response: Decodable>(
        _ path: String,
        query: [URLQueryItem]? = nil,
        headers: [String: String] = [:]
    ) async throws -> Response {
        let data = try await sendData(path, method: .delete, bodyData: nil, query: query, headers: headers)
        return try decode(data)
    }

    // MARK: Convenience verbs — discardable raw response

    @discardableResult
    func post<Body: Encodable>(
        _ path: String,
        body: Body,
        query: [URLQueryItem]? = nil,
        headers: [String: String] = [:]
    ) async throws -> Data {
        try await requestData(path, method: .post, body: body, query: query, headers: headers)
    }

    @discardableResult
    func delete(
        _ path: String,
        query: [URLQueryItem]? = nil,
        headers: [String: String] = [:]
    ) async throws -> Data {
        try await sendData(path, method: .delete, bodyData: nil, query: query, headers: headers)
    }

    // MARK: Generic entry points

    /// Perform a request with an Encodable body and decode the response.
    func request<Body: Encodable, Response: Decodable>(
        _ path: String,
        method: HTTPMethod,
        body: Body,
        query: [URLQueryItem]? = nil,
        headers: [String: String] = [:]
    ) async throws -> Response {
        let data = try await requestData(path, method: method, body: body, query: query, headers: headers)
        return try decode(data)
    }

    /// Perform a bodyless request and decode the response.
    func request<Response: Decodable>(
        _ path: String,
        method: HTTPMethod,
        query: [URLQueryItem]? = nil,
        headers: [String: String] = [:]
    ) async throws -> Response {
        let data = try await sendData(path, method: method, bodyData: nil, query: query, headers: headers)
        return try decode(data)
    }

    /// Perform a request with an Encodable body and return the raw response data.
    @discardableResult
    func requestData<Body: Encodable>(
        _ path: String,
        method: HTTPMethod,
        body: Body,
        query: [URLQueryItem]? = nil,
        headers: [String: String] = [:]
    ) async throws -> Data {
        let bodyData: Data
        do {
            bodyData = try encoder.encode(body)
        } catch {
            throw APIError.encodingFailed(error)
        }
        return try await sendData(path, method: method, bodyData: bodyData, query: query, headers: headers)
    }

    // MARK: Form-encoded (e.g. OAuth2 token endpoints)

    /// POST `application/x-www-form-urlencoded` form fields and decode the
    /// response. Used for OAuth2 token endpoints which don't accept JSON bodies.
    func postForm<Response: Decodable>(
        _ path: String,
        form: [String: String],
        headers: [String: String] = [:]
    ) async throws -> Response {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let bodyString = form
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")

        var merged = headers
        merged["Content-Type"] = "application/x-www-form-urlencoded"

        // Token endpoints must NOT go through the tokenProvider (would recurse).
        let data = try await sendData(path,
                                      method: .post,
                                      bodyData: bodyString.data(using: .utf8),
                                      query: nil,
                                      headers: merged,
                                      applyAuth: false)
        return try decode(data)
    }

    // MARK: Core

    private func decode<Response: Decodable>(_ data: Data) throws -> Response {
        if Response.self == Data.self { return data as! Response }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.decodingFailed(error)
        }
    }

    private func sendData(
        _ path: String,
        method: HTTPMethod,
        bodyData: Data?,
        query: [URLQueryItem]?,
        headers: [String: String],
        applyAuth: Bool = true,
        isRetry: Bool = false
    ) async throws -> Data {
        // Inject a fresh bearer token per request (no shared-state mutation).
        var allHeaders = headers
        if applyAuth, let tokenProvider, let token = try await tokenProvider() {
            allHeaders["Authorization"] = "Bearer \(token)"
        }

        let request = try makeRequest(path: path, method: method, bodyData: bodyData, query: query, headers: allHeaders)

        #if DEBUG
        Self.logRequest(request)
        #endif

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            #if DEBUG
            print("⬇️ [API] ✗ \(request.httpMethod ?? "?") \(request.url?.absoluteString ?? "?")\n   error: \(error.localizedDescription)")
            #endif
            throw APIError.requestFailed(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        #if DEBUG
        Self.logResponse(data, status: http.statusCode, url: request.url)
        #endif

        // Token expired/rejected mid-flight → force a refresh and retry once.
        if http.statusCode == 401, applyAuth, !isRetry, let tokenRefresher {
            _ = try await tokenRefresher()
            return try await sendData(path,
                                      method: method,
                                      bodyData: bodyData,
                                      query: query,
                                      headers: headers,
                                      applyAuth: applyAuth,
                                      isRetry: true)
        }

        guard (200..<300).contains(http.statusCode) else {
            throw APIError.unacceptableStatus(code: http.statusCode, data: data)
        }
        return data
    }

    #if DEBUG
    private static func logRequest(_ request: URLRequest) {
        var lines = ["⬆️ [API] \(request.httpMethod ?? "?") \(request.url?.absoluteString ?? "?")"]
        if let headers = request.allHTTPHeaderFields, !headers.isEmpty {
            lines.append("   headers: \(headers)")
        }
        if let body = request.httpBody, let text = String(data: body, encoding: .utf8), !text.isEmpty {
            lines.append("   body: \(text)")
        }
        print(lines.joined(separator: "\n"))
    }

    private static func logResponse(_ data: Data, status: Int, url: URL?) {
        let mark = (200..<300).contains(status) ? "✓" : "✗"
        var line = "⬇️ [API] \(mark) \(status) \(url?.absoluteString ?? "?")"
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            let trimmed = text.count > 4000 ? String(text.prefix(4000)) + "…(truncated)" : text
            line += "\n   response: \(trimmed)"
        }
        print(line)
    }
    #endif

    private func makeRequest(
        path: String,
        method: HTTPMethod,
        bodyData: Data?,
        query: [URLQueryItem]?,
        headers: [String: String]
    ) throws -> URLRequest {
        guard let url = resolvedURL(for: path, query: query) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method.rawValue

        // Layer headers: defaults first, then per-request overrides.
        for (key, value) in defaultHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if let bodyData {
            request.httpBody = bodyData
            // Default the content type only when the caller hasn't set one.
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }

        return request
    }

    private func resolvedURL(for path: String, query: [URLQueryItem]?) -> URL? {
        let base: URL?
        if let absolute = URL(string: path), absolute.scheme != nil {
            base = absolute
        } else if let baseURL {
            // Join base + path with exactly one slash, preserving the base path
            // (e.g. ".../api/v1/") and any internal slashes in `path`.
            var root = baseURL.absoluteString
            if root.hasSuffix("/") { root.removeLast() }
            let suffix = path.hasPrefix("/") ? path : "/" + path
            base = URL(string: root + suffix)
        } else {
            base = URL(string: path)
        }

        guard let base else { return nil }
        guard let query, !query.isEmpty else { return base }

        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return base
        }
        components.queryItems = (components.queryItems ?? []) + query
        return components.url
    }
}
