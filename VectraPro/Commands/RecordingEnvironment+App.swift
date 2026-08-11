//
//  RecordingEnvironment+App.swift
//  VectraPro
//
//  The app's answer to "what computed this recording".
//
//  Lives in the app rather than in ATCReplayKit because only the app knows its own bundle, and the
//  package must not read one — a package that inspects `Bundle.main` behaves differently depending on
//  who linked it, which is exactly the sort of hidden coupling that makes a recorded environment
//  untrustworthy.
//

import Foundation
import ATCReplayKit

extension Bundle {

    /// `"1.4.2 (317)"` — marketing version and build number.
    ///
    /// Both, because either alone is ambiguous: two builds of the same version compute the same way or
    /// they do not, and the build number is what tells them apart.
    var buildVersionForRecording: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }
}

extension RecordingEnvironment {

    /// `"iOS 26.3"`. The OS supplies `sin` and `cos`, so it is part of the answer to "would this
    /// compute the same" — see `DeterminismSelfCheck`.
    public static var currentPlatform: String {
        #if os(iOS)
        return "iOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #elseif os(macOS)
        return "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #else
        return ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }

    /// The environment this build and device represent.
    public static func current(bundle: Bundle = .main) -> RecordingEnvironment {
        RecordingEnvironment(buildVersion: bundle.buildVersionForRecording,
                             platform: currentPlatform)
    }
}
