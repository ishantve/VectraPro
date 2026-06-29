//
//  HTTPMethod.swift
//  VectraPro
//
//  Supported HTTP verbs for APIManager requests.
//

import Foundation

enum HTTPMethod: String {
    case get    = "GET"
    case post   = "POST"
    case put    = "PUT"
    case patch  = "PATCH"
    case delete = "DELETE"
}
