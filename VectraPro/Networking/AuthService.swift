//
//  AuthService.swift
//  VectraPro
//
//  Logs in against the selected organization's `AuthURL` (Keycloak / OpenID
//  Connect token endpoint), persists the session, and refreshes the access
//  token (grant_type=refresh_token) when it expires.
//
//  APIManager asks `validAccessToken()` before every request (via its
//  tokenProvider), so calls always carry a fresh token and refresh happens
//  transparently.
//

import Combine
import Foundation

/// OAuth2 token response from the AuthURL.
struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?
    let refreshExpiresIn: Int?
    let tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken      = "access_token"
        case refreshToken     = "refresh_token"
        case expiresIn        = "expires_in"
        case refreshExpiresIn = "refresh_expires_in"
        case tokenType        = "token_type"
    }
}

/// Error body Keycloak returns on a failed token request.
struct OAuthErrorResponse: Decodable {
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

enum AuthError: LocalizedError {
    case missingConfig
    case message(String)

    var errorDescription: String? {
        switch self {
        case .missingConfig:
            return "No organization configuration found. Please re-enter the Organization ID."
        case .message(let text):
            return text
        }
    }
}

@MainActor
final class AuthService: ObservableObject {

    static let shared = AuthService()

    private(set) var session: Session?
    var nickname: String? { session?.nickname }
    var username: String? { session?.username }
    var isLoggedIn: Bool { session != nil }

    /// Set when the refresh token is no longer valid — observers (RootView)
    /// reset to the Organization ID screen and show a "session expired" message.
    @Published var sessionExpired = false

    /// De-dupes concurrent refreshes (refresh tokens are often single-use).
    private var refreshTask: Task<String, Error>?

    private init() {
        session = SessionStore.load()
        // Every request fetches a valid token through this provider.
        APIManager.shared.tokenProvider = { [weak self] in
            try await self?.validAccessToken()
        }
        // A 401 mid-request forces a refresh, then the request retries.
        APIManager.shared.tokenRefresher = { [weak self] in
            try await self?.refresh()
        }
    }

    // MARK: Login

    /// Username + password login (OAuth2 password grant).
    func login(username: String, password: String) async throws {
        try await authenticate(
            extra: ["grant_type": "password", "username": username, "password": password],
            nickname: nil,
            username: username
        )
    }

    /// Nickname login (org `Nickname == "Allowed"`) — client-credentials grant.
    func login(nickname: String) async throws {
        try await authenticate(
            extra: ["grant_type": "client_credentials"],
            nickname: nickname,
            username: nil
        )
    }

    func logout() {
        session = nil
        refreshTask?.cancel()
        refreshTask = nil
        SessionStore.clear()
        APIManager.shared.removeDefaultHeader(forKey: "Authorization")
    }

    /// The refresh token is dead — clear everything and signal observers to
    /// reset to the Organization ID screen.
    private func expireSession() {
        logout()
        sessionExpired = true
    }

    /// Store the userId resolved from /nickName/user into the session.
    func setUserId(_ userId: String) {
        session?.userId = userId
        if let session { SessionStore.save(session) }
    }

    // MARK: Token

    /// A currently-valid access token, refreshing first if it has expired.
    /// Returns nil when there's no session at all.
    func validAccessToken() async throws -> String? {
        guard let session else { return nil }
        if session.isAccessTokenValid { return session.accessToken }
        guard session.isRefreshTokenValid else {
            expireSession()
            throw AuthError.message("Session expired. Please log in again.")
        }
        return try await refresh()
    }

    /// Refresh the access token using the refresh token. Concurrent callers
    /// share a single in-flight refresh.
    @discardableResult
    func refresh() async throws -> String {
        if let refreshTask { return try await refreshTask.value }
        let task = Task { try await performRefresh() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    // MARK: Core

    private func performRefresh() async throws -> String {
        guard let current = session else { throw AuthError.message("No active session.") }
        do {
            try await authenticate(
                extra: ["grant_type": "refresh_token", "refresh_token": current.refreshToken],
                nickname: current.nickname,
                username: current.username
            )
        } catch let error as AuthError {
            // The token endpoint rejected the refresh token → it's expired/invalid.
            expireSession()
            throw error
        }
        guard let token = session?.accessToken else { throw AuthError.message("Token refresh failed.") }
        return token
    }

    /// Calls the token endpoint, builds/updates the session, and persists it.
    private func authenticate(extra: [String: String], nickname: String?, username: String?) async throws {
        guard let config = ConfigStore.shared.current(), !config.authURL.isEmpty else {
            throw AuthError.missingConfig
        }

        var form = extra
        form["client_id"] = config.stratagemMobileID
        form["client_secret"] = config.stratagemMobileSecret

        do {
            let token: TokenResponse = try await APIManager.shared.postForm(config.authURL, form: form)
            let now = Date()
            let updated = Session(
                accessToken: token.accessToken,
                refreshToken: token.refreshToken ?? session?.refreshToken ?? "",
                accessTokenExpiresAt: now.addingTimeInterval(TimeInterval(token.expiresIn ?? 300)),
                refreshTokenExpiresAt: token.refreshExpiresIn.map { now.addingTimeInterval(TimeInterval($0)) }
                    ?? session?.refreshTokenExpiresAt,
                // Exactly the nickname for this login: nil for username/password
                // (so /nickName/user is skipped), the entered value for nickname
                // login, and the preserved value on refresh.
                nickname: nickname,
                username: username,
                userId: session?.userId
            )
            session = updated
            SessionStore.save(updated)
        } catch let APIError.unacceptableStatus(_, data) {
            if let oauth = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data),
               let description = oauth.errorDescription ?? oauth.error {
                throw AuthError.message(description)
            }
            throw AuthError.message("Login failed. Please check your credentials.")
        }
    }
}
