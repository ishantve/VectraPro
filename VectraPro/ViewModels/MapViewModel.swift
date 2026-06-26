//
//  MapViewModel.swift
//  VectraPro
//
//  Drives the radar map: range rings, enabled runways, localizers, design.
//

import Combine
import CoreLocation
import Foundation

final class MapViewModel: ObservableObject {

    // MARK: - Radar

    let center: CLLocationCoordinate2D = MapConfiguration.center
    let rings: [RangeRing] = MapConfiguration.rings
    let defaultZoom: Float = MapConfiguration.defaultZoom

    // MARK: - Runways & approaches

    @Published private(set) var runways: [Runway] = RunwayData.igiAirport

    /// Approaches currently enabled (shown with runway + localizer). Driven
    /// locally for now; will be supplied by the backend later.
    @Published private(set) var enabledApproaches: Set<ApproachID> = []

    // MARK: - Aircraft

    @Published private(set) var aircraft: [Aircraft] = []

    private var simulationTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private let tickInterval = 1.0          // seconds

    /// App-wide shared instance so every scene's map shows the same live state.
    static let shared = MapViewModel()
    private var tickCount = 0
    private let historySampleTicks = 3      // sample a trail dot every N ticks
    private let maxHistoryPoints = 8

    // MARK: - Drawing

    @Published var isDrawing = false
    @Published private(set) var pendingStart: CLLocationCoordinate2D?

    private lazy var commandController = CommandController(mapViewModel: self)

    /// Services 0–360 radials; default set on until the API supplies them.
    let radialManager = RadialManager()

    /// Replace enabled radials (e.g. from the API).
    func setEnabledRadials(_ degrees: Set<Int>) {
        objectWillChange.send()
        radialManager.setEnabled(degrees)
    }

    func enableRadial(_ degree: Int) {
        objectWillChange.send()
        radialManager.enable(degree)
    }

    func disableRadial(_ degree: Int) {
        objectWillChange.send()
        radialManager.disable(degree)
    }

    /// Emits a zoom delta (+1 in / −1 out) from the zoom buttons.
    let zoomPublisher = PassthroughSubject<Double, Never>()

    func zoom(by delta: Double) {
        zoomPublisher.send(delta)
    }

    /// Emits a bearing (0 N, 90 E, 180 S, 270 W) to nudge the map via keyboard.
    let panPublisher = PassthroughSubject<Double, Never>()

    func pan(towardBearing bearing: Double) {
        panPublisher.send(bearing)
    }

    init() {
        enabledApproaches = defaultEnabledApproaches()
        aircraft = [makeRandomAircraft()]
    }

    // MARK: - Voice commands

    /// Entry point for a transcribed command — parsed & applied centrally.
    func handleVoiceCommand(_ transcript: String) {
        commandController.process(transcript)
    }

    /// Apply parsed commands to the (currently single) aircraft.
    func apply(_ commands: [AircraftCommand]) {
        guard !aircraft.isEmpty else { return }
        for command in commands {
            switch command {
            case .heading(let heading):
                aircraft[0].targetHeading = heading
            case .flightLevel(let flightLevel):
                aircraft[0].altitudeFeet = Double(flightLevel) * 100
            case .speed(let knots):
                aircraft[0].targetSpeedKnots = knots
            }
        }
    }

    deinit {
        simulationTimer?.invalidate()
    }

    // MARK: - Simulation

    func startSimulation() {
        guard simulationTimer == nil else { return }
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        simulationTimer = timer
    }

    func stopSimulation() {
        simulationTimer?.invalidate()
        simulationTimer = nil
    }

    /// Full fresh start — clears radar state and re-spawns. Called each time the
    /// screen opens so reopening renders new.
    func reset() {
        stopSimulation()
        tickCount = 0
        runways = RunwayData.igiAirport
        enabledApproaches = defaultEnabledApproaches()
        radialManager.setEnabled(RadialManager.defaultRadials)
        pendingStart = nil
        aircraft = [makeRandomAircraft()]
        startSimulation()
    }

    /// Advance every aircraft along its heading by the distance covered at its
    /// speed during one tick. distance = speed × time.
    private func tick() {
        tickCount += 1

        for index in aircraft.indices {
            // Gradual, speed-dependent turn toward any commanded heading.
            turnTowardTarget(&aircraft[index], dt: tickInterval)

            // Gradual acceleration / deceleration toward any commanded speed.
            adjustSpeed(&aircraft[index], dt: tickInterval)

            // Sample a history point for the trail.
            if tickCount % historySampleTicks == 0 {
                aircraft[index].history.append(aircraft[index].position)
                if aircraft[index].history.count > maxHistoryPoints {
                    aircraft[index].history.removeFirst()
                }
            }

            let metersPerSecond = aircraft[index].speedKnots * Distance.metersPerNauticalMile / 3600
            let distance = metersPerSecond * tickInterval
            aircraft[index].position = Geo.offset(
                from: aircraft[index].position,
                distanceMeters: distance,
                bearingDegrees: aircraft[index].headingDegrees
            )
        }
    }

    /// Standard bank angle for the turn-rate model (heavier transport ~25°).
    private let maxBankDegrees = 25.0

    /// Turn the aircraft toward its commanded heading at a bank-limited rate.
    /// Rate of turn (°/s) = 1091 × tan(bank) / TAS(kt) — so faster aircraft turn
    /// more slowly (larger radius), like a real radar target.
    private func turnTowardTarget(_ aircraft: inout Aircraft, dt: Double) {
        guard let target = aircraft.targetHeading else { return }

        let current = aircraft.headingDegrees
        var diff = (target - current).truncatingRemainder(dividingBy: 360)
        if diff > 180 { diff -= 360 } else if diff < -180 { diff += 360 }

        let rate = 1091.0 * tan(maxBankDegrees * .pi / 180.0) / max(aircraft.speedKnots, 1)
        let step = rate * dt

        if abs(diff) <= step {
            aircraft.headingDegrees = normalizeHeading(target)
            aircraft.targetHeading = nil   // reached
        } else {
            aircraft.headingDegrees = normalizeHeading(current + (diff >= 0 ? step : -step))
        }
    }

    private func normalizeHeading(_ heading: Double) -> Double {
        let value = heading.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }

    /// Typical jet rates: accelerates slowly, decelerates a bit faster (drag).
    private let accelKnotsPerSecond = 1.5
    private let decelKnotsPerSecond = 2.0

    private func adjustSpeed(_ aircraft: inout Aircraft, dt: Double) {
        guard let target = aircraft.targetSpeedKnots else { return }

        let diff = target - aircraft.speedKnots
        let step = (diff > 0 ? accelKnotsPerSecond : decelKnotsPerSecond) * dt

        if abs(diff) <= step {
            aircraft.speedKnots = target
            aircraft.targetSpeedKnots = nil   // reached
        } else {
            aircraft.speedKnots += diff > 0 ? step : -step
        }
    }

    /// Spawn an aircraft outside the 60 NM radius, heading roughly inbound so
    /// it crosses the scope.
    private func makeRandomAircraft() -> Aircraft {
        let spawnBearing = Double.random(in: 0..<360)
        let rangeNM = Double.random(in: 60..<70)
        let position = Geo.offset(
            from: center,
            distanceMeters: rangeNM * Distance.metersPerNauticalMile,
            bearingDegrees: spawnBearing
        )

        // Inbound heading = back toward the centre, ± some spread.
        let inbound = (spawnBearing + 180).truncatingRemainder(dividingBy: 360)
        let heading = (inbound + Double.random(in: -40...40) + 360).truncatingRemainder(dividingBy: 360)

        return Aircraft(
            callsign: Self.randomCallsign(),
            position: position,
            headingDegrees: heading
        )
    }

    private static func randomCallsign() -> String {
        let airlines = ["ACA", "AIC", "IGO", "VTI", "UAE", "SIA"]
        let prefix = airlines.randomElement() ?? "ACA"
        return prefix + String(Int.random(in: 10...99))
    }

    // MARK: - Approach enabling

    /// Every approach across all runways (both ends), for the toggle UI.
    var allApproaches: [Approach] {
        runways.flatMap(\.approaches)
    }

    func isEnabled(_ id: ApproachID) -> Bool {
        enabledApproaches.contains(id)
    }

    func toggleApproach(_ id: ApproachID) {
        if enabledApproaches.contains(id) {
            enabledApproaches.remove(id)
        } else {
            enabledApproaches.insert(id)
        }
    }

    func runway(for id: UUID) -> Runway? {
        runways.first { $0.id == id }
    }

    /// Persist a dragged data-block position as a polar offset from the
    /// aircraft so it stays attached as the aircraft moves.
    func setLabelOffset(for id: UUID, bearingDegrees: Double, distanceMeters: Double) {
        guard let index = aircraft.firstIndex(where: { $0.id == id }) else { return }
        aircraft[index].labelBearingDegrees = bearingDegrees
        aircraft[index].labelDistanceMeters = distanceMeters
    }

    // MARK: - Drawing flow

    func toggleDrawing() {
        isDrawing.toggle()
        pendingStart = nil
    }

    func handleTap(at coordinate: CLLocationCoordinate2D) {
        guard isDrawing else { return }

        if let start = pendingStart {
            addRunway(from: start, to: coordinate)
            pendingStart = nil
        } else {
            pendingStart = coordinate
        }
    }

    // MARK: - Private

    /// Enable a single approach by default so the radar isn't empty.
    private func defaultEnabledApproaches() -> Set<ApproachID> {
        guard let approach = runways.first?.approaches.last else { return [] }
        return [approach.id]
    }

    private func addRunway(from start: CLLocationCoordinate2D,
                           to end: CLLocationCoordinate2D) {
        let bearing = Geo.bearing(from: start, to: end)
        let length = Geo.distanceMeters(from: start, to: end)

        let runway = Runway(
            endA: RunwayThreshold(
                designator: Runway.designator(forBearing: bearing),
                coordinate: start
            ),
            endB: RunwayThreshold(
                designator: Runway.designator(forBearing: bearing + 180),
                coordinate: end
            ),
            lengthMeters: length
        )

        runways.append(runway)
        // Show the freshly drawn runway right away.
        enabledApproaches.insert(ApproachID(runwayID: runway.id, side: .a))
    }
}
