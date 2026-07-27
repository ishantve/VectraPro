//
//  APIManager.swift
//  NetworkKit
//
//  Lightweight async/await networking layer over URLSession. GET/POST/PUT/PATCH/
//  DELETE with an Encodable body and a Decodable response. Headers are layered:
//  `defaultHeaders` merged with per-request `headers` (per-request wins). Auth is
//  injected via `tokenProvider` / `tokenRefresher` closures, so this stays
//  decoupled from any specific auth implementation.
//

import Foundation

public final class APIManager {

    public static let shared = APIManager()

    /// Optional base URL. When set, relative request paths ("/users") resolve
    /// against it; absolute URLs also work.
    public var baseURL: URL?

    /// Headers sent on every request (per-request headers override on clash).
    public private(set) var defaultHeaders: [String: String] = [
        "Accept": "application/json"
    ]

    /// Default timeout for requests that don't override it.
    public var timeout: TimeInterval = 30

    /// Supplies a valid bearer token before each request (refreshing if needed).
    /// Token endpoints bypass this to avoid recursion.
    public var tokenProvider: (() async throws -> String?)?

    /// Forces a token refresh and returns the new token, on a 401 retry.
    public var tokenRefresher: (() async throws -> String?)?

    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(session: URLSession = .shared,
                encoder: JSONEncoder = JSONEncoder(),
                decoder: JSONDecoder = JSONDecoder()) {
        self.session = session
        self.encoder = encoder
        self.decoder = decoder
    }

    // MARK: Header management

    public func setDefaultHeader(_ value: String, forKey key: String) {
        defaultHeaders[key] = value
    }

    public func removeDefaultHeader(forKey key: String) {
        defaultHeaders[key] = nil
    }

    // MARK: Convenience verbs — decoded response

    public func get<Response: Decodable>(
        _ path: String, query: [URLQueryItem]? = nil, headers: [String: String] = [:]
    ) async throws -> Response {
        let data = try await sendData(path, method: .get, bodyData: nil, query: query, headers: headers)
        return try decode(data)
    }

    public func post<Body: Encodable, Response: Decodable>(
        _ path: String, body: Body, query: [URLQueryItem]? = nil, headers: [String: String] = [:]
    ) async throws -> Response {
        let data = try await requestData(path, method: .post, body: body, query: query, headers: headers)
        return try decode(data)
    }

    public func put<Body: Encodable, Response: Decodable>(
        _ path: String, body: Body, query: [URLQueryItem]? = nil, headers: [String: String] = [:]
    ) async throws -> Response {
        let data = try await requestData(path, method: .put, body: body, query: query, headers: headers)
        return try decode(data)
    }

    public func patch<Body: Encodable, Response: Decodable>(
        _ path: String, body: Body, query: [URLQueryItem]? = nil, headers: [String: String] = [:]
    ) async throws -> Response {
        let data = try await requestData(path, method: .patch, body: body, query: query, headers: headers)
        return try decode(data)
    }

    public func delete<Response: Decodable>(
        _ path: String, query: [URLQueryItem]? = nil, headers: [String: String] = [:]
    ) async throws -> Response {
        let data = try await sendData(path, method: .delete, bodyData: nil, query: query, headers: headers)
        return try decode(data)
    }

    // MARK: Convenience verbs — discardable raw response

    @discardableResult
    public func post<Body: Encodable>(
        _ path: String, body: Body, query: [URLQueryItem]? = nil, headers: [String: String] = [:]
    ) async throws -> Data {
        try await requestData(path, method: .post, body: body, query: query, headers: headers)
    }

    @discardableResult
    public func delete(
        _ path: String, query: [URLQueryItem]? = nil, headers: [String: String] = [:]
    ) async throws -> Data {
        try await sendData(path, method: .delete, bodyData: nil, query: query, headers: headers)
    }

    // MARK: Generic entry points

    public func request<Body: Encodable, Response: Decodable>(
        _ path: String, method: HTTPMethod, body: Body,
        query: [URLQueryItem]? = nil, headers: [String: String] = [:]
    ) async throws -> Response {
        let data = try await requestData(path, method: method, body: body, query: query, headers: headers)
        return try decode(data)
    }

    public func request<Response: Decodable>(
        _ path: String, method: HTTPMethod,
        query: [URLQueryItem]? = nil, headers: [String: String] = [:]
    ) async throws -> Response {
        let data = try await sendData(path, method: method, bodyData: nil, query: query, headers: headers)
        return try decode(data)
    }

    @discardableResult
    public func requestData<Body: Encodable>(
        _ path: String, method: HTTPMethod, body: Body,
        query: [URLQueryItem]? = nil, headers: [String: String] = [:]
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

    public func postForm<Response: Decodable>(
        _ path: String, form: [String: String], headers: [String: String] = [:]
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

        let data = try await sendData(path, method: .post,
                                      bodyData: bodyString.data(using: .utf8),
                                      query: nil, headers: merged, applyAuth: false)
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
        _ path: String, method: HTTPMethod, bodyData: Data?,
        query: [URLQueryItem]?, headers: [String: String],
        applyAuth: Bool = true, isRetry: Bool = false
    ) async throws -> Data {
        var allHeaders = headers
        if applyAuth, let tokenProvider, let token = try await tokenProvider() {
            allHeaders["Authorization"] = "Bearer \(token)"
        }

        let request = try makeRequest(path: path, method: method, bodyData: bodyData, query: query, headers: allHeaders)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.requestFailed(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        // Token expired mid-flight → refresh once and retry.
        if http.statusCode == 401, applyAuth, !isRetry, let tokenRefresher {
            _ = try await tokenRefresher()
            return try await sendData(path, method: method, bodyData: bodyData,
                                      query: query, headers: headers,
                                      applyAuth: applyAuth, isRetry: true)
        }

        guard (200..<300).contains(http.statusCode) else {
            throw APIError.unacceptableStatus(code: http.statusCode, data: data)
        }
        return data
    }

    private func makeRequest(
        path: String, method: HTTPMethod, bodyData: Data?,
        query: [URLQueryItem]?, headers: [String: String]
    ) throws -> URLRequest {
        guard let url = resolvedURL(for: path, query: query) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method.rawValue

        for (key, value) in defaultHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if let bodyData {
            request.httpBody = bodyData
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

// MARK: - APIManager + APIEndpoint

public extension APIManager {

    /// Bodyless request (GET / DELETE / bodyless POST) → decoded response.
    func request<Response: Decodable>(
        _ endpoint: some APIEndpoint, headers: [String: String] = [:]
    ) async throws -> Response {
        try await request(endpoint.path, method: endpoint.method,
                          query: endpoint.query, headers: headers)
    }

    /// Request with an Encodable body → decoded response.
    func request<Body: Encodable, Response: Decodable>(
        _ endpoint: some APIEndpoint, body: Body, headers: [String: String] = [:]
    ) async throws -> Response {
        try await request(endpoint.path, method: endpoint.method, body: body,
                          query: endpoint.query, headers: headers)
    }

    /// Request with an Encodable body, ignoring the response body.
    @discardableResult
    func request<Body: Encodable>(
        _ endpoint: some APIEndpoint, body: Body, headers: [String: String] = [:]
    ) async throws -> Data {
        try await requestData(endpoint.path, method: endpoint.method, body: body,
                              query: endpoint.query, headers: headers)
    }

    /// Bodyless request, ignoring the response body (e.g. DELETE).
    @discardableResult
    func request(
        _ endpoint: some APIEndpoint, headers: [String: String] = [:]
    ) async throws -> Data {
        switch endpoint.method {
        case .delete:
            return try await delete(endpoint.path, query: endpoint.query, headers: headers)
        default:
            let data: Data = try await request(endpoint.path, method: endpoint.method,
                                               query: endpoint.query, headers: headers)
            return data
        }
    }
}
