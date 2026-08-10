//
//  TranscriptionService.swift
//  VectraPro
//
//  Sends a recorded WAV directly to the Azure Speech-to-Text REST API
//  (custom model via endpointId) and returns the recognized text.
//

import Foundation

public enum TranscriptionError: Error {
    case notConfigured
    case invalidURL
    case badResponse
}

public struct TranscriptionService {

    public init() {}

    public func transcribe(wavURL: URL) async throws -> String {
        let config = AzureConfiguration.shared

        guard !config.azureSubscriptionKey.isEmpty, !config.azureEndpointId.isEmpty else {
            throw TranscriptionError.notConfigured
        }

        let urlString = "https://\(config.azureRegion).stt.speech.microsoft.com"
            + "/speech/recognition/conversation/cognitiveservices/v1"
            + "?language=en-US&endpointId=\(config.azureEndpointId)"

        guard let url = URL(string: urlString) else {
            throw TranscriptionError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.addValue(config.azureSubscriptionKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")

        let audioData = try Data(contentsOf: wavURL)
        let (data, response) = try await URLSession.shared.upload(for: request, from: audioData)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TranscriptionError.badResponse
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["DisplayText"] as? String) ?? ""
    }
}
