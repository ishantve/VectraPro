//
//  Umbrella.swift
//  ATCReplayStore
//
//  The old module name for the storage layer. See `ATCReplayKit/Umbrella.swift` — same reason, same lifetime:
//  it keeps the application's imports untouched while the packaging changes underneath, and it goes away when
//  call sites import `ReplayPersistence` directly.
//

@_exported import ReplayPersistence
