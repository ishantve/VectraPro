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

    /// Radar center. Defaults to IGI; replaced by the started exercise's
    /// map location so the range rings draw around it.
    private(set) var center: CLLocationCoordinate2D = MapConfiguration.center
    /// Map-layer visibility (driven by the "Map Layers" menu toggles).
    @Published var layers: [String: Bool] = [
        "Radials": true, "Fixes": true, "Fixes Names": true, "Zone": true, "Holding": true
    ]
    func layerOn(_ name: String) -> Bool { layers[name] ?? false }

    /// Set a layer toggle, cascading to dependent labels when a parent turns on or off.
    func setLayer(_ name: String, _ value: Bool) {
        layers[name] = value
        switch name {
        case "Fixes":
            layers["Fixes Names"] = value
        case "Radials":
            layers["Radials Names"] = value
        default: break
        }
    }

    let rings: [RangeRing] = MapConfiguration.rings
    /// Wide Area Control Radar rings (100/150/200/250 NM), same centre.
    let areaControlRings: [RangeRing] = MapConfiguration.areaControlRings
    let defaultZoom: Float = MapConfiguration.defaultZoom

    /// Runways/approaches derived from the started exercise (nil → IGI defaults).
    private var exerciseRunways: [Runway]?
    private var exerciseApproaches: Set<ApproachID>?
    /// VOR fixes from the started exercise (radials drawn from each).
    private(set) var fixes: [ExerciseDetail.Fix] = []
    /// Airspace zones from the started exercise (plotted as polygons).
    private(set) var zones: [ExerciseDetail.Zone] = []
    /// Obstructions ("obstacles") from the started exercise.
    private(set) var obstructions: [ExerciseDetail.Obstruction] = []

    // MARK: - Traffic (hangar lists)

    /// Aircraft spawned into the hangar lists per the exercise frequency.
    /// These appear in the lists only — not drawn on the map.
    @Published private(set) var traffic: [Aircraft] = []

    /// Everything shown in the hangar lists: the on-map aircraft + spawned traffic.
    var listAircraft: [Aircraft] { aircraft + traffic }

    /// Spawn-frequency config per category (from the exercise).
    private var freqDeparture: ExerciseDetail.FrequencyOfDeparture?
    private var freqArrival: ExerciseDetail.FrequencyOfArrival?
    private var freqEnroute: ExerciseDetail.FrequencyOfEnroute?

    /// How a category spawns: a fixed interval (Custom) or random intervals up
    /// to a quota (Random).
    private enum SpawnMode {
        case custom(interval: Double)
        case random(remaining: Int)
    }
    /// Active spawners (one per category that has Custom/Random frequency).
    private var spawners: [(category: FlightCategory, mode: SpawnMode, countdown: Double)] = []

    /// Multi-aircraft spawning (from the exercise).
    private var isMultiMode = false
    private var airspaceCapacity = 1
    private var aircraftSpawningCount = 1
    private var airlines: [ExerciseDetail.Airline] = []
    private var aircraftTypes: [ExerciseDetail.AircraftType] = []

    /// Random-mode interval choices (seconds).
    private let randomIntervals: [Double] = [15, 20, 30, 45, 60, 90]

    /// Split `total` into `parts` descending whole numbers (priority gets more),
    /// e.g. (15, 3) → [6,5,4]; (15, 2) → [8,7]; (15, 1) → [15].
    private func descendingSplit(total: Int, parts: Int) -> [Int] {
        guard parts > 0 else { return [] }
        guard total > 0 else { return Array(repeating: 0, count: parts) }

        // Descending-by-1 sequence centred to sum ≈ total, clamped ≥ 0.
        let a = Double(total + parts * (parts - 1) / 2) / Double(parts)
        var values = (0..<parts).map { max(0, Int((a - Double($0)).rounded())) }

        // Fix the sum exactly, adjusting the highest-priority slots first.
        var diff = total - values.reduce(0, +)
        var i = 0
        let safety = parts * (total + parts) + 1
        while diff != 0, i < safety {
            let idx = i % parts
            if diff > 0 {
                values[idx] += 1; diff -= 1
            } else if values[idx] > 0 {
                values[idx] -= 1; diff += 1
            }
            i += 1
        }
        return values
    }

    /// Radial lines for the exercise's VOR fixes (empty when none).
    func fixRadialLines() -> [MapLine] {
        FixRadialRenderer.lines(fixes: fixes)
    }

    /// Label positions / names / bearings for named VOR radials.
    func fixRadialLabels() -> [FixRadialRenderer.RadialLabel] {
        FixRadialRenderer.labels(fixes: fixes, center: center)
    }

    /// Polygon shapes (border + fill + label) for the exercise's airspace zones.
    func zoneShapes() -> [ZoneShape] {
        ZoneRenderer.shapes(zones: zones)
    }

    /// Waypoint-type fixes, shown as triangle icons on the radar.
    var waypointFixes: [ExerciseDetail.Fix] {
        fixes.filter { $0.type?.uppercased() == "WAYPOINT" }
    }

    /// Holding-type fixes, shown as the holding icon on the radar.
    var holdingFixes: [ExerciseDetail.Fix] {
        fixes.filter { $0.type?.uppercased() == "HOLDING" }
    }

    /// Apply the started exercise: center the radar and derive runways +
    /// enabled approaches from the API. Built once here so UUIDs stay stable
    /// across `reset()`.
    func applyExercise(_ detail: ExerciseDetail) {
        if let lat = detail.mapLatitude, let lon = detail.mapLongitude {
            center = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }

        fixes = detail.fixes
        zones = detail.zones
        obstructions = detail.obstructions
        freqDeparture = detail.frequencyOfDeparture
        freqArrival = detail.frequencyOfArrival
        freqEnroute = detail.frequencyOfEnroute

        // Multi-aircraft spawning config + identities (airlines / aircraft types).
        isMultiMode = detail.isMultiMode ?? false
        airspaceCapacity = detail.airspaceCapacity ?? 1
        aircraftSpawningCount = detail.aircraftSpawningCount ?? 1
        airlines = detail.airlines
        aircraftTypes = detail.aircrafts

        #if DEBUG
        print("""
        ========== EXERCISE DETAIL ==========
        name: \(detail.exerciseName)   icao: \(detail.icaoCode ?? "—")   airport: \(detail.airportName ?? "—")
        map: \(detail.mapLatitude ?? 0), \(detail.mapLongitude ?? 0)
        isMultiMode: \(String(describing: detail.isMultiMode))
        airspaceCapacity: \(String(describing: detail.airspaceCapacity))
        aircraftSpawningCount: \(String(describing: detail.aircraftSpawningCount))
        → initialSpawnCount: \(initialSpawnCount())
        runways: \(detail.runways.count)   fixes: \(fixes.count)   zones: \(zones.count)   obstructions: \(obstructions.count)
        airlines (\(airlines.count)): \(airlines.map { "\($0.icaoCode ?? "?")/\($0.callSign ?? "?")" })
        aircrafts (\(aircraftTypes.count)): \(aircraftTypes.map { "\($0.icaoCode ?? "?")=\($0.model ?? "?") [\($0.icaoWTC ?? "?")]" })
        freqDeparture: type=\(detail.frequencyOfDeparture?.type ?? "—") flights=\(String(describing: detail.frequencyOfDeparture?.departureFlights)) time=\(String(describing: detail.frequencyOfDeparture?.departureFlightsTimeValue))
        freqArrival:   type=\(detail.frequencyOfArrival?.type ?? "—") flights=\(String(describing: detail.frequencyOfArrival?.arrivalFlights)) time=\(String(describing: detail.frequencyOfArrival?.arrivalFlightsTimeValue))
        freqEnroute:   type=\(detail.frequencyOfEnroute?.type ?? "—") flights=\(String(describing: detail.frequencyOfEnroute?.enrouteFlights)) time=\(String(describing: detail.frequencyOfEnroute?.enrouteFlightsTimeValue))
        =====================================
        """)
        #endif

        var built: [Runway] = []
        var enabled: Set<ApproachID> = []
        for rw in detail.runways {
            let strips = rw.runwayStrips ?? []
            guard strips.count >= 2,
                  let aLat = strips[0].stripLatitude, let aLon = strips[0].stripLongitude,
                  let bLat = strips[1].stripLatitude, let bLon = strips[1].stripLongitude else { continue }

            let runway = Runway(
                endA: RunwayThreshold(designator: strips[0].stripName ?? "",
                                      coordinate: CLLocationCoordinate2D(latitude: aLat, longitude: aLon)),
                endB: RunwayThreshold(designator: strips[1].stripName ?? "",
                                      coordinate: CLLocationCoordinate2D(latitude: bLat, longitude: bLon)),
                lengthMeters: nil
            )
            built.append(runway)
            if strips[0].displayLocalizer == true { enabled.insert(ApproachID(runwayID: runway.id, side: .a)) }
            if strips[1].displayLocalizer == true { enabled.insert(ApproachID(runwayID: runway.id, side: .b)) }
        }

        if built.isEmpty {
            exerciseRunways = nil
            exerciseApproaches = nil
        } else {
            exerciseRunways = built
            exerciseApproaches = enabled
            runways = built
            enabledApproaches = enabled
        }
    }

    // MARK: - Runways & approaches

    @Published private(set) var runways: [Runway] = []

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
                aircraft[0].turnDirection = nil           // shortest way
                aircraft[0].targetHeading = heading
            case .headingTurn(let heading, let direction):
                aircraft[0].turnDirection = direction      // forced left / right
                aircraft[0].targetHeading = heading
            case .relativeTurn(let degrees, let direction):
                let current = aircraft[0].headingDegrees
                let target = direction == .left ? current - degrees : current + degrees
                aircraft[0].turnDirection = direction
                aircraft[0].targetHeading = normalizeHeading(target)
            case .presentHeading:
                aircraft[0].turnDirection = nil
                aircraft[0].targetHeading = nil            // stop turning, hold current
            case .flightLevel(let flightLevel):
                // Climb / descend & maintain — gradual via targetAltitude.
                aircraft[0].minAltitudeFeet = nil
                aircraft[0].maxAltitudeFeet = nil
                aircraft[0].targetAltitudeFeet = Double(flightLevel) * 100
            case .altitudeBlock(let low, let high):
                // Maintain block — set floor/ceiling; move into range if outside.
                let lo = Double(min(low, high)) * 100
                let hi = Double(max(low, high)) * 100
                aircraft[0].minAltitudeFeet = lo
                aircraft[0].maxAltitudeFeet = hi
                let alt = aircraft[0].altitudeFeet
                if alt < lo { aircraft[0].targetAltitudeFeet = lo }
                else if alt > hi { aircraft[0].targetAltitudeFeet = hi }
                else { aircraft[0].targetAltitudeFeet = nil }
            case .speed(let knots):
                // Maintain an exact speed — clears any earlier floor/ceiling.
                aircraft[0].minSpeedKnots = nil
                aircraft[0].maxSpeedKnots = nil
                aircraft[0].targetSpeedKnots = knots
            case .minSpeed(let knots):
                // "Maintain xxx or greater" — set a floor; speed up if below it.
                aircraft[0].maxSpeedKnots = nil
                aircraft[0].minSpeedKnots = knots
                if aircraft[0].speedKnots < knots { aircraft[0].targetSpeedKnots = knots }
            case .maxSpeed(let knots):
                // "Do not exceed xxx" — set a ceiling; slow down if above it.
                aircraft[0].minSpeedKnots = nil
                aircraft[0].maxSpeedKnots = knots
                if aircraft[0].speedKnots > knots { aircraft[0].targetSpeedKnots = knots }
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
        // Runways come only from the started exercise; none otherwise.
        runways = exerciseRunways ?? []
        enabledApproaches = exerciseApproaches ?? []
        radialManager.setEnabled(RadialManager.defaultRadials)
        pendingStart = nil
        // Initial aircraft count toward the capacity and are distributed across
        // the active categories with the same priority logic as the lists.
        aircraft = initialCategories().map { makeRandomAircraft(category: $0) }
        resetTraffic()
        startSimulation()
    }

    /// How many aircraft to spawn on the radar at start.
    ///  • single mode → 1
    ///  • multi mode  → aircraftSpawningCount, capped at airspaceCapacity
    private func initialSpawnCount() -> Int {
        guard isMultiMode else { return 1 }
        let capacity = max(airspaceCapacity, 0)
        let requested = max(aircraftSpawningCount, 0)
        return max(1, min(requested, capacity))
    }

    /// A category is active if its frequency type is Custom or Random.
    private func isActiveType(_ type: String?) -> Bool {
        let t = type?.lowercased()
        return t == "custom" || t == "random"
    }

    /// Active categories in priority order (arrival → departure → enroute).
    private func activeCategories() -> [FlightCategory] {
        var result: [FlightCategory] = []
        if isActiveType(freqArrival?.type)   { result.append(.arrival) }
        if isActiveType(freqDeparture?.type) { result.append(.departure) }
        if isActiveType(freqEnroute?.type)   { result.append(.enroute) }
        return result
    }

    /// Categories for the initially-spawned (on-map) aircraft. Only Arrival &
    /// Enroute spawn on the radar — Departures leave from the runway, so they
    /// live only in the hangar list (via the frequency spawner).
    private func initialCategories() -> [FlightCategory] {
        let count = initialSpawnCount()
        let cats = activeCategories().filter { $0 != .departure }
        guard !cats.isEmpty else { return Array(repeating: .arrival, count: count) }
        let split = descendingSplit(total: count, parts: cats.count)
        return zip(cats, split).flatMap { Array(repeating: $0.0, count: $0.1) }
    }

    /// Clear the hangar lists and rebuild the spawners from the exercise.
    /// Priority order (most → least traffic): arrival, departure, enroute.
    private func resetTraffic() {
        traffic = []
        spawners = []

        let configs: [(category: FlightCategory, type: String?, flights: Int?, minutes: Int?)] = [
            (.arrival,   freqArrival?.type,   freqArrival?.arrivalFlights,     freqArrival?.arrivalFlightsTimeValue),
            (.departure, freqDeparture?.type, freqDeparture?.departureFlights, freqDeparture?.departureFlightsTimeValue),
            (.enroute,   freqEnroute?.type,   freqEnroute?.enrouteFlights,     freqEnroute?.enrouteFlightsTimeValue)
        ]

        // Random categories share the total cap, distributed by priority. A
        // "none" (or missing) type spawns nothing, so its share goes to the rest.
        let randomCats = configs.filter { $0.type?.lowercased() == "random" }.map(\.category)
        let quotas = descendingSplit(total: airspaceCapacity, parts: randomCats.count)
        let quotaForCategory = Dictionary(uniqueKeysWithValues: zip(randomCats, quotas))

        for config in configs {
            switch config.type?.lowercased() {
            case "custom":
                guard let flights = config.flights, flights > 0,
                      let minutes = config.minutes, minutes > 0 else { continue }
                let interval = Double(minutes) * 60.0 / Double(flights)
                spawners.append((config.category, .custom(interval: interval), interval))
            case "random":
                guard let quota = quotaForCategory[config.category], quota > 0 else { continue }
                spawners.append((config.category, .random(remaining: quota), randomIntervals.randomElement() ?? 30))
            default:
                continue   // "none" / missing → no spawner
            }
        }
    }

    /// Advance every aircraft along its heading by the distance covered at its
    /// speed during one tick. distance = speed × time.
    private func tick() {
        tickCount += 1

        // Spawn traffic into the hangar lists per the exercise frequency.
        advanceSpawners()

        for index in aircraft.indices {
            // Gradual, speed-dependent turn toward any commanded heading.
            turnTowardTarget(&aircraft[index], dt: tickInterval)

            // Gradual acceleration / deceleration toward any commanded speed.
            adjustSpeed(&aircraft[index], dt: tickInterval)

            // Gradual climb / descent toward any commanded altitude.
            adjustAltitude(&aircraft[index], dt: tickInterval)

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

        // A forced direction (TLH/TRH/relative) overrides the shortest path.
        if let direction = aircraft.turnDirection {
            if direction == .right, diff < 0 { diff += 360 }
            if direction == .left, diff > 0 { diff -= 360 }
        }

        let rate = 1091.0 * tan(maxBankDegrees * .pi / 180.0) / max(aircraft.speedKnots, 1)
        let step = rate * dt

        if abs(diff) <= step {
            aircraft.headingDegrees = normalizeHeading(target)
            aircraft.targetHeading = nil   // reached
            aircraft.turnDirection = nil
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

    /// Typical climb / descent rate (~2000 ft/min).
    private let climbFeetPerSecond = 33.0
    private let descentFeetPerSecond = 33.0

    private func adjustAltitude(_ aircraft: inout Aircraft, dt: Double) {
        guard let target = aircraft.targetAltitudeFeet else { return }

        let diff = target - aircraft.altitudeFeet
        let step = (diff > 0 ? climbFeetPerSecond : descentFeetPerSecond) * dt

        if abs(diff) <= step {
            aircraft.altitudeFeet = target
            aircraft.targetAltitudeFeet = nil   // reached
        } else {
            aircraft.altitudeFeet += diff > 0 ? step : -step
        }
    }

    /// Spawn an aircraft outside the 60 NM radius, heading roughly inbound so
    /// it crosses the scope.
    private func makeRandomAircraft(category: FlightCategory = .arrival) -> Aircraft {
        let position: CLLocationCoordinate2D
        let heading: Double

        if category == .arrival, let radial = randomVORRadial() {
            // Spawn on a (visible) VOR radial at ~70 NM out (or its end if
            // shorter), heading to the centre.
            let spawnDistance = min(70 * Distance.metersPerNauticalMile, radial.lengthMeters)
            position = Geo.offset(from: radial.origin,
                                  distanceMeters: spawnDistance,
                                  bearingDegrees: radial.angle)
            heading = Geo.bearing(from: position, to: center)
        } else {
            let spawnBearing = Double.random(in: 0..<360)
            let rangeNM = Double.random(in: 60..<70)
            position = Geo.offset(from: center,
                                  distanceMeters: rangeNM * Distance.metersPerNauticalMile,
                                  bearingDegrees: spawnBearing)
            let inbound = (spawnBearing + 180).truncatingRemainder(dividingBy: 360)
            heading = (inbound + Double.random(in: -40...40) + 360).truncatingRemainder(dividingBy: 360)
        }

        var aircraft = Aircraft(
            callsign: makeCallsign(),
            position: position,
            headingDegrees: heading
        )
        aircraft.category = category
        aircraft.aircraftType = aircraftTypes.randomElement()?.icaoCode
        return aircraft
    }

    /// A random VOR-fix radial (origin, bearing, drawn length) — the radials
    /// actually shown on the radar. Nil if the exercise has none.
    private func randomVORRadial() -> (origin: CLLocationCoordinate2D, angle: Double, lengthMeters: Double)? {
        var options: [(CLLocationCoordinate2D, Double, Double)] = []
        for fix in fixes where fix.type?.uppercased() == "VOR" {
            guard let lat = fix.latitude, let lon = fix.longitude, let radials = fix.radials else { continue }
            let origin = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            for r in radials {
                guard let angle = r.angle, let distanceNM = r.distance, distanceNM > 0 else { continue }
                // FixRadialRenderer draws each radial at 3× its reported distance.
                options.append((origin, angle, distanceNM * 3 * Distance.metersPerNauticalMile))
            }
        }
        return options.randomElement()
    }

    /// Callsign from the exercise airlines (ICAO code + flight number), or a
    /// built-in fallback when the exercise has none.
    private func makeCallsign() -> String {
        if let code = airlines.compactMap({ $0.icaoCode }).filter({ !$0.isEmpty }).randomElement() {
            return code + String(Int.random(in: 100...999))
        }
        return Self.randomCallsign()
    }

    /// Advance every spawner; add a list aircraft when its countdown elapses.
    private func advanceSpawners() {
        for i in spawners.indices {
            spawners[i].countdown -= tickInterval
            guard spawners[i].countdown <= 0 else { continue }

            // Global cap = airspaceCapacity, counting the initially-spawned
            // aircraft too (map targets + hangar traffic).
            guard listAircraft.count < airspaceCapacity else {
                spawners[i].countdown = .infinity
                continue
            }

            switch spawners[i].mode {
            case .custom(let interval):
                traffic.append(makeListAircraft(category: spawners[i].category))
                spawners[i].countdown += interval

            case .random(let remaining):
                guard remaining > 0 else {
                    spawners[i].countdown = .infinity   // quota done — stop
                    continue
                }
                traffic.append(makeListAircraft(category: spawners[i].category))
                let left = remaining - 1
                spawners[i].mode = .random(remaining: left)
                // Pick a fresh random interval for the next one (or stop).
                spawners[i].countdown = left > 0 ? (randomIntervals.randomElement() ?? 30) : .infinity
            }
        }
    }

    /// A hangar-list aircraft (not drawn on the map): callsign, FL, speed, runway.
    private func makeListAircraft(category: FlightCategory) -> Aircraft {
        var ac = Aircraft(callsign: Self.randomCallsign(),
                          position: center,
                          headingDegrees: 0)
        ac.category = category
        ac.altitudeFeet = Double(Int.random(in: 80...350)) * 100   // FL080–FL350
        ac.speedKnots = Double(Int.random(in: 180...450))
        if let runway = runways.randomElement() {
            ac.assignedRunway = Bool.random() ? runway.endA.designator : runway.endB.designator
        }
        return ac
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
