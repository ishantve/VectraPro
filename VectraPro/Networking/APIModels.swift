//
//  APIModels.swift
//  VectraPro
//
//  Decodable models for the post-login API responses. Decoding is defensive
//  (missing/null fields fall back to defaults) so one odd record can't fail the call.
//

import Foundation

// MARK: - Organizations

struct Organization: Decodable {
    let id: String
    let name: String
    let description: String
    let logo: String
    let orgLevelRole: String
    let isSingleOrg: Bool
    let gameOrder: [String]

    enum CodingKeys: String, CodingKey {
        case id, name, description, logo, orgLevelRole, isSingleOrg, gameOrder
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id           = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        name         = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        description  = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? ""
        logo         = (try? c.decodeIfPresent(String.self, forKey: .logo)) ?? ""
        orgLevelRole = (try? c.decodeIfPresent(String.self, forKey: .orgLevelRole)) ?? ""
        isSingleOrg  = (try? c.decodeIfPresent(Bool.self, forKey: .isSingleOrg)) ?? false
        gameOrder    = (try? c.decodeIfPresent([String].self, forKey: .gameOrder)) ?? []
    }
}

// MARK: - Games

/// `/games` returns an object: { "Games": [...], "pagination": {...} }.
struct GamesResponse: Decodable {
    let games: [Game]
    let pagination: Pagination?

    enum CodingKeys: String, CodingKey {
        case games = "Games"
        case pagination
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        games = (try? c.decodeIfPresent([Game].self, forKey: .games)) ?? []
        pagination = try? c.decodeIfPresent(Pagination.self, forKey: .pagination)
    }
}

struct Pagination: Decodable {
    let total: Int?
    let limit: Int?
    let page: Int?
    let pages: Int?
}

// MARK: - Nickname user

/// Response from POST /nickName/user.
struct NickNameUser: Decodable {
    let status: Bool
    let record: String
    let userId: String

    enum CodingKeys: String, CodingKey {
        case status, record, userId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = (try? c.decodeIfPresent(Bool.self, forKey: .status)) ?? false
        record = (try? c.decodeIfPresent(String.self, forKey: .record)) ?? ""
        userId = (try? c.decodeIfPresent(String.self, forKey: .userId)) ?? ""
    }
}

/// A single game from /organizations/{id}/games.
struct Game: Decodable {
    let id: String?
    let name: String?
    let description: String?
    let icon: String?
    let version: String?

    enum CodingKeys: String, CodingKey {
        case id, name, description, icon, version
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try? c.decodeIfPresent(String.self, forKey: .id)
        name        = try? c.decodeIfPresent(String.self, forKey: .name)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        icon        = try? c.decodeIfPresent(String.self, forKey: .icon)
        version     = try? c.decodeIfPresent(String.self, forKey: .version)
    }
}
