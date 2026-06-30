//
//  Session.swift
//  VectraPro
//
//  The logged-in user's auth session (tokens + expiry). Persisted to the
//  Keychain so it survives relaunches and can be refreshed when the access
//  token expires.
//

import Foundation

struct Session: Codable {
    var accessToken: String
    var refreshToken: String
    var accessTokenExpiresAt: Date
    var refreshTokenExpiresAt: Date?
    var nickname: String?
    /// The username entered for username/password login (nil for nickname login).
    var username: String?
    var userId: String?

    /// True while the access token is still good (30s leeway for clock/latency).
    var isAccessTokenValid: Bool {
        Date().addingTimeInterval(30) < accessTokenExpiresAt
    }

    /// True while the refresh token can still be used to mint a new access token.
    var isRefreshTokenValid: Bool {
        guard let refreshTokenExpiresAt else { return true }
        return Date() < refreshTokenExpiresAt
    }
}
