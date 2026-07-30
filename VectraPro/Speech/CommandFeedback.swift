//
//  CommandFeedback.swift
//  VectraPro
//
//  What the simulation is allowed to say.
//
//  `MapViewModel` used to reach `CommandFeedbackManager.shared` directly from eight
//  places, which made it untestable in the most literal way: constructing one in a
//  test spoke out loud through the device synthesiser. Naming the dependency lets a
//  test pass a spy and assert on what would have been said.
//
//  Narrow on purpose — four calls, all the simulation actually makes. Anything
//  wider would just be the manager's whole surface with an extra step.
//

import ATCSimKit

@MainActor
protocol CommandFeedback {

    /// ICAO phraseology already rendered from a template — spoken as it stands.
    func readback(_ spoken: String)

    /// Legacy English assembled from the command enum, for the paths that have no
    /// template readback yet.
    func commandAccepted(callsign: String, commands: [AircraftCommand])

    /// A rejection the controller needs to hear.
    func commandError(_ phrase: String)

    /// No aircraft answers to the callsign that was given.
    func aircraftNotFound()
}

extension CommandFeedbackManager: CommandFeedback {}
