//
//  DeviceCapability.swift
//  VectraPro
//
//  Detects whether this iPad can drive a separate, interactive external display
//  (Stage Manager extended mode). Only Apple Silicon (M-series) iPads can —
//  others only mirror or show app-provided (non-interactive) content.
//

import UIKit

enum DeviceCapability {

    /// True on M-series iPads → interactive multi-window experience.
    static var supportsExtendedDisplay: Bool {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return false }
        return isAppleSiliconIPad
    }

    static let modelIdentifier: String = {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "unknown"
        #else
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { raw in
            let pointer = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
            return String(cString: pointer)
        }
        #endif
    }()

    private static let appleSiliconIPads: Set<String> = [
        "iPad13,4", "iPad13,5", "iPad13,6", "iPad13,7",
        "iPad13,8", "iPad13,9", "iPad13,10", "iPad13,11",
        "iPad13,16", "iPad13,17",
        "iPad14,3", "iPad14,4", "iPad14,5", "iPad14,6",
        "iPad14,8", "iPad14,9", "iPad14,10", "iPad14,11",
        "iPad16,3", "iPad16,4", "iPad16,5", "iPad16,6",
        "iPad17,1", "iPad17,2", "iPad17,3", "iPad17,4",
    ]

    private static var isAppleSiliconIPad: Bool {
        appleSiliconIPads.contains(modelIdentifier)
    }
}
