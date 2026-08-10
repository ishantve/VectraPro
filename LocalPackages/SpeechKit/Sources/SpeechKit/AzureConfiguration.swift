//
//  ConfigurationManager.swift
//  VectraPro
//
//  Created by Ishant Zibal on 25/06/26.
//


import Foundation

class AzureConfiguration {
    static let shared = AzureConfiguration()
    private init() {}
    
    private lazy var plist: [String: Any]? = {
        guard let path = Bundle.main.path(forResource: "AzureConfig", ofType: "plist"),
              let plist = NSDictionary(contentsOfFile: path) as? [String: Any] else {
            print("Warning: AzureConfig.plist not found")
            return nil
        }
        return plist
    }()
    
    var azureSubscriptionKey: String {
        return plist?["SubscriptionKey"] as? String ?? ""
    }
    
    var azureRegion: String {
        return plist?["Region"] as? String ?? "eastus2"
    }
    
    var azureEndpointId: String {
        return plist?["EndpointId"] as? String ?? ""
    }
}
