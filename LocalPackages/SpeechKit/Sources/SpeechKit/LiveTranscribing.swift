//
//  LiveTranscribing.swift
//  VectraPro
//
//  Streaming recognizer that emits transcript text live while the user speaks.
//

import Foundation

public protocol LiveTranscribing: AnyObject {
    /// Called on the main thread with the latest transcript as it streams in.
    var onPartial: ((String) -> Void)? { get set }

    func start()
    func stop()
}
