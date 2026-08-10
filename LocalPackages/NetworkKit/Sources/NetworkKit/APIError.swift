//
//  APIError.swift
//  NetworkKit
//
//  Errors surfaced by APIManager. The transport cases (invalidURL, requestFailed,
//  unacceptableStatus, …) are generic; a few domain cases (organization / access)
//  are kept here so the app has a single networking error type — move them app-
//  side if NetworkKit is reused elsewhere.
//

import Foundation

public enum APIError: LocalizedError {
    case invalidURL
    case encodingFailed(Error)
    case requestFailed(Error)
    case invalidResponse
    /// No config in the UDC response matched the given Organization ID.
    case organizationNotFound
    /// The user has no organization in the /organizations response.
    case noOrganizationAccess
    /// The Vectra game wasn't present for the organization.
    case noApplicationAccess
    /// Non-2xx status. Carries the code and the raw body (for server messages).
    case unacceptableStatus(code: Int, data: Data)
    case decodingFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The request URL was invalid."
        case .encodingFailed(let error):
            return "Failed to encode the request body: \(error.localizedDescription)"
        case .requestFailed(let error):
            return "The network request failed: \(error.localizedDescription)"
        case .invalidResponse:
            return "The server returned an unexpected response."
        case .organizationNotFound:
            return "No organization matched that ID."
        case .noOrganizationAccess:
            return "Sorry, It seems you don't have access to this organization."
        case .noApplicationAccess:
            return "Sorry, It seems you don't have permission to access this application."
        case .unacceptableStatus(let code, _):
            return "The server returned status code \(code)."
        case .decodingFailed(let error):
            return "Failed to decode the response: \(error.localizedDescription)"
        }
    }

    /// HTTP status code when the failure was a non-2xx response.
    public var statusCode: Int? {
        if case .unacceptableStatus(let code, _) = self { return code }
        return nil
    }
}
