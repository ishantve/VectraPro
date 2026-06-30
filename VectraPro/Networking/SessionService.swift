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

@MainActor
final class SessionService {

    static let shared = SessionService()

    /// The selected organization (single object, not the array).
    private(set) var organization: Organization?
    /// The game whose name contains "Vectra" (single object, not the array).
    private(set) var vectraGame: Game?
    /// Response from POST /nickName/user (nickname login).
    private(set) var nickNameUser: NickNameUser?

    /// Call once after a successful login.
    func loadInitialData() async throws {
        // 1) Organizations → keep the particular organization object.
        let orgs: [Organization] = try await APIManager.shared.request(.organizations)
        let org = orgs.first
        organization = org

        guard let orgID = org?.id, !orgID.isEmpty else {
            throw APIError.noOrganizationAccess
        }

        // 2) Games — org id is in the path; OrganizationId header is also sent.
        let response: GamesResponse = try await APIManager.shared.request(
            .games(orgID: orgID),
            headers: ["OrganizationId": orgID]
        )

        // Keep only the game that contains "Vectra".
        guard let game = response.games.first(where: {
            ($0.name ?? "").localizedCaseInsensitiveContains("vectra")
        }) else {
            throw APIError.noApplicationAccess
        }
        vectraGame = game

        // From /games onward, every API call must carry BOTH OrganizationId and
        // gameId — set them as default headers so all subsequent calls include them.
        APIManager.shared.setDefaultHeader(orgID, forKey: "OrganizationId")
        if let gameId = game.id, !gameId.isEmpty {
            APIManager.shared.setDefaultHeader(gameId, forKey: "gameId")
        }

        // 3) Nickname user — only for nickname login. Passes the nickname entered
        //    on the login screen as the `nickName` query parameter.
        //    OrganizationId + gameId are sent automatically (default headers).
        if let nickname = AuthService.shared.nickname, !nickname.isEmpty {
            let user: NickNameUser = try await APIManager.shared.request(
                .nickNameUser(nickName: nickname)
            )
            nickNameUser = user
            // Persist the resolved userId into the saved session.
            if !user.userId.isEmpty { AuthService.shared.setUserId(user.userId) }
        }
    }
}
