//
//  OrganizationConfig.swift
//  VectraPro
//
//  SwiftData model persisting the organization config fetched from UDC, so the
//  last-known config survives app relaunches.
//

import Foundation
import SwiftData

@Model
final class OrganizationConfig {

    @Attribute(.unique) var id: Int
    var organizationID: String
    var authURL: String
    var apiURL: String
    var analyticsID: Int
    var analyticsURL: String
    var issuerURL: String
    var eramClientSecret: String?
    var eramClientID: String?
    var eramRedirectURL: String?
    var nickname: String
    var basicVectoringClientID: String
    var basicVectoringSecret: String
    var stratagemMobileID: String
    var stratagemMobileSecret: String
    var metricsURL: String
    var chatBotURL: String
    var showIvyIcon: Bool
    /// When this config was last saved from UDC.
    var savedAt: Date

    init(
        id: Int,
        organizationID: String,
        authURL: String,
        apiURL: String,
        analyticsID: Int,
        analyticsURL: String,
        issuerURL: String,
        eramClientSecret: String?,
        eramClientID: String?,
        eramRedirectURL: String?,
        nickname: String,
        basicVectoringClientID: String,
        basicVectoringSecret: String,
        stratagemMobileID: String,
        stratagemMobileSecret: String,
        metricsURL: String,
        chatBotURL: String,
        showIvyIcon: Bool,
        savedAt: Date
    ) {
        self.id = id
        self.organizationID = organizationID
        self.authURL = authURL
        self.apiURL = apiURL
        self.analyticsID = analyticsID
        self.analyticsURL = analyticsURL
        self.issuerURL = issuerURL
        self.eramClientSecret = eramClientSecret
        self.eramClientID = eramClientID
        self.eramRedirectURL = eramRedirectURL
        self.nickname = nickname
        self.basicVectoringClientID = basicVectoringClientID
        self.basicVectoringSecret = basicVectoringSecret
        self.stratagemMobileID = stratagemMobileID
        self.stratagemMobileSecret = stratagemMobileSecret
        self.metricsURL = metricsURL
        self.chatBotURL = chatBotURL
        self.showIvyIcon = showIvyIcon
        self.savedAt = savedAt
    }

    /// Build a persistable model from a decoded UDC config.
    convenience init(from config: UDCConfig, savedAt: Date = Date()) {
        self.init(
            id: config.id,
            organizationID: config.organizationID,
            authURL: config.authURL,
            apiURL: config.apiURL,
            analyticsID: config.analyticsID,
            analyticsURL: config.analyticsURL,
            issuerURL: config.issuerURL,
            eramClientSecret: config.eramClientSecret,
            eramClientID: config.eramClientID,
            eramRedirectURL: config.eramRedirectURL,
            nickname: config.nickname,
            basicVectoringClientID: config.basicVectoringClientID,
            basicVectoringSecret: config.basicVectoringSecret,
            stratagemMobileID: config.stratagemMobileID,
            stratagemMobileSecret: config.stratagemMobileSecret,
            metricsURL: config.metricsURL,
            chatBotURL: config.chatBotURL,
            showIvyIcon: config.showIvyIcon,
            savedAt: savedAt
        )
    }
}
