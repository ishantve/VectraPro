//
//  APIEndpoint.swift
//  NetworkKit
//
//  A route the client can call: a path, a verb, and optional query items. Apps
//  conform their own endpoint type (usually an enum) to this and call
//  `APIManager.request(_:)`.
//

import Foundation

public protocol APIEndpoint {
    var path: String { get }
    var method: HTTPMethod { get }
    var query: [URLQueryItem]? { get }
}

public extension APIEndpoint {
    var query: [URLQueryItem]? { nil }
}
