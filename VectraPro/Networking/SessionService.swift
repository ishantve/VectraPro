//
//  SessionService.swift
//  VectraPro
//
//  Post-login bootstrap against the org's APIUrl (already set on APIManager):
//  fetch /organizations first, then /games — passing the organization id from
//  the first call in the `OrganizationId` header of the second.
//
//  Stores a single Organization object and the single Game whose name contains
//  "Vectra" (not the full arrays).
//

import Foundation
import NetworkKit

@MainActor
final class SessionService {

    static let shared = SessionService()

    // Collaborators — injected (default to the shared instances) so this
    // bootstrap flow's dependencies are explicit rather than global reaches.
    private let api: APIManager
    private let auth: AuthService

    private init(api: APIManager? = nil, auth: AuthService? = nil) {
        self.api = api ?? .shared
        self.auth = auth ?? .shared
    }

    /// Call once after a successful login.
    func loadInitialData() async throws {
        // 1) Organizations → keep the particular organization object.
        let orgs: [Organization] = try await api.request(Endpoint.organizations)
        let org = orgs.first

        guard let orgID = org?.id, !orgID.isEmpty else {
            throw APIError.noOrganizationAccess
        }

        // 2) Games — org id is in the path; OrganizationId header is also sent.
        let response: GamesResponse = try await api.request(
            Endpoint.games(orgID: orgID),
            headers: ["OrganizationId": orgID]
        )

        // Keep only the game that contains "Vectra".
        guard let game = response.games.first(where: {
            ($0.name ?? "").localizedCaseInsensitiveContains("vectra")
        }) else {
            throw APIError.noApplicationAccess
        }

        // From /games onward, every API call must carry BOTH OrganizationId and
        // gameId — set them as default headers so all subsequent calls include them.
        api.setDefaultHeader(orgID, forKey: "OrganizationId")
        if let gameId = game.id, !gameId.isEmpty {
            api.setDefaultHeader(gameId, forKey: "gameId")
        }

        // 3) Nickname user — only for nickname login. Passes the nickname entered
        //    on the login screen as the `nickName` query parameter.
        //    OrganizationId + gameId are sent automatically (default headers).
        if let nickname = auth.nickname, !nickname.isEmpty {
            let user: NickNameUser = try await api.request(
                Endpoint.nickNameUser(nickName: nickname)
            )
            // Persist the resolved userId into the saved session.
            if !user.userId.isEmpty { auth.setUserId(user.userId) }
        }
    }
}
