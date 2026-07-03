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

        #if DEBUG
        print("========== ZONES (\(zones.count)) ==========")
        for z in zones {
            print("  zone: id=\(z.zoneId ?? "—")  name=\(z.zoneName ?? "—")  type=\(z.zoneType ?? "—")  isActive=\(String(describing: z.isActive))  color=\(z.color ?? "—")  colliders=\(z.colliders?.count ?? 0)")
            for (i, c) in (z.colliders ?? []).enumerated() {
                print("    [\(i)] lat=\(String(describing: c.latitude))  lon=\(String(describing: c.longitude))")
            }
        }
        print("==========================================")
        #endif
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
    /// Aircraft IDs whose 2.5 NM circles are touching (distance < 5 NM) — yellow warning.
    @Published private(set) var yellowConflictIDs: Set<UUID> = []
    /// Aircraft IDs within 3 NM of another aircraft — red critical alert.
    @Published private(set) var redConflictIDs: Set<UUID> = []
    /// Aircraft IDs whose collider ring is touching a zone boundary (approaching wall).
    @Published private(set) var zoneConflictIDs: Set<UUID> = []
    /// Aircraft IDs whose position is inside a fix collider (circle for HOLDING, triangle for others).
    @Published private(set) var fixConflictIDs: Set<UUID> = []
    /// Alternates true/false every simulation tick — drives data-block blink for zone conflicts.
    @Published private(set) var blinkState: Bool = false

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
        detectConflicts()
        detectZoneConflicts()
        detectFixConflicts()
        blinkState.toggle()
    }

    /// Checks every aircraft pair for separation loss and physical collisions.
    /// Yellow = separation circles touching (< 5 NM).
    /// Red    = critical separation (< 3 NM).
    /// Destroy = body diamond or nose diamond overlap → both aircraft removed.
    private func detectConflicts() {
        var yellows  = Set<UUID>()
        var reds     = Set<UUID>()
        var bodyHits = Set<UUID>()

        for i in 0..<aircraft.count {
            for j in (i + 1)..<aircraft.count {
                let a = aircraft[i], b = aircraft[j]

                // Use a's position as flat-Earth origin for both.
                let aXY = (x: 0.0, y: 0.0)
                let bXY = flatXY(origin: a.position, target: b.position)
                let aH  = a.headingDegrees * .pi / 180
                let bH  = b.headingDegrees * .pi / 180

                // Nose centres in the same flat space.
                let nA = (x: aXY.x + a.noseOffsetNM * 1852 * sin(aH),
                          y: aXY.y + a.noseOffsetNM * 1852 * cos(aH))
                let nB = (x: bXY.x + b.noseOffsetNM * 1852 * sin(bH),
                          y: bXY.y + b.noseOffsetNM * 1852 * cos(bH))

                // Body–body (diamond), nose–body / body–nose (rect vs diamond), nose–nose (rect).
                let hit = diamondsOverlap(cx1: aXY.x, cy1: aXY.y, f1: a.bodyForwardNM * 1852, s1: a.bodySideNM * 1852, h1: aH,
                                          cx2: bXY.x, cy2: bXY.y, f2: b.bodyForwardNM * 1852, s2: b.bodySideNM * 1852, h2: bH)
                       || rectDiamondOverlap(rx: nA.x, ry: nA.y, rf: a.noseForwardNM * 1852, rs: a.noseSideNM * 1852, rh: aH,
                                             dx: bXY.x, dy: bXY.y, df: b.bodyForwardNM * 1852, ds: b.bodySideNM * 1852, dh: bH)
                       || rectDiamondOverlap(rx: nB.x, ry: nB.y, rf: b.noseForwardNM * 1852, rs: b.noseSideNM * 1852, rh: bH,
                                             dx: aXY.x, dy: aXY.y, df: a.bodyForwardNM * 1852, ds: a.bodySideNM * 1852, dh: aH)
                       || rectsOverlap(cx1: nA.x, cy1: nA.y, f1: a.noseForwardNM * 1852, s1: a.noseSideNM * 1852, h1: aH,
                                       cx2: nB.x, cy2: nB.y, f2: b.noseForwardNM * 1852, s2: b.noseSideNM * 1852, h2: bH)
                if hit {
                    bodyHits.insert(a.id); bodyHits.insert(b.id)
                    continue
                }

                let hDistNM = hypot(bXY.x, bXY.y) / 1852.0
                let vDistFt = abs(a.altitudeFeet - b.altitudeFeet)
                guard vDistFt < 1000 else { continue }
                if hDistNM < (a.colliderRadiusNM + b.colliderRadiusNM) {
                    yellows.insert(a.id); yellows.insert(b.id)
                }
                if hDistNM < 3.0 {
                    reds.insert(a.id); reds.insert(b.id)
                }
            }
        }

        if !bodyHits.isEmpty {
            aircraft.removeAll { bodyHits.contains($0.id) }
            traffic.removeAll  { bodyHits.contains($0.id) }
            yellows.subtract(bodyHits)
            reds.subtract(bodyHits)
        }

        if yellows != yellowConflictIDs { yellowConflictIDs = yellows }
        if reds    != redConflictIDs    { redConflictIDs    = reds    }
    }

    // MARK: - Diamond collision helpers

    /// True if point (px, py) lies inside a diamond centred at (cx, cy).
    /// The diamond has half-extents `forwardM` (along heading) and `sideM` (perpendicular).
    private func pointInDiamond(px: Double, py: Double,
                                 cx: Double, cy: Double,
                                 forwardM: Double, sideM: Double,
                                 headingRad: Double) -> Bool {
        let dx = px - cx, dy = py - cy
        let fwd   = dx * sin(headingRad) + dy * cos(headingRad)
        let right = dx * cos(headingRad) - dy * sin(headingRad)
        return abs(fwd) / forwardM + abs(right) / sideM <= 1.0
    }

    /// The 4 vertices of a diamond in flat-Earth metres.
    private func diamondVerts(cx: Double, cy: Double,
                               forwardM: Double, sideM: Double,
                               headingRad: Double) -> [(Double, Double)] {
        let sinH = sin(headingRad), cosH = cos(headingRad)
        return [
            (cx + forwardM * sinH,  cy + forwardM * cosH),   // front
            (cx + sideM   * cosH,   cy - sideM   * sinH),   // right
            (cx - forwardM * sinH,  cy - forwardM * cosH),   // back
            (cx - sideM   * cosH,   cy + sideM   * sinH),   // left
        ]
    }

    /// True if two diamonds overlap (centre-in-other + vertex-in-other tests).
    private func diamondsOverlap(cx1: Double, cy1: Double, f1: Double, s1: Double, h1: Double,
                                  cx2: Double, cy2: Double, f2: Double, s2: Double, h2: Double) -> Bool {
        // Centre of each inside the other.
        if pointInDiamond(px: cx2, py: cy2, cx: cx1, cy: cy1, forwardM: f1, sideM: s1, headingRad: h1) { return true }
        if pointInDiamond(px: cx1, py: cy1, cx: cx2, cy: cy2, forwardM: f2, sideM: s2, headingRad: h2) { return true }
        // Vertices of each inside the other.
        for (vx, vy) in diamondVerts(cx: cx1, cy: cy1, forwardM: f1, sideM: s1, headingRad: h1) {
            if pointInDiamond(px: vx, py: vy, cx: cx2, cy: cy2, forwardM: f2, sideM: s2, headingRad: h2) { return true }
        }
        for (vx, vy) in diamondVerts(cx: cx2, cy: cy2, forwardM: f2, sideM: s2, headingRad: h2) {
            if pointInDiamond(px: vx, py: vy, cx: cx1, cy: cy1, forwardM: f1, sideM: s1, headingRad: h1) { return true }
        }
        return false
    }

    /// True if point lies inside an OBB rectangle aligned to `headingRad`.
    private func pointInRect(px: Double, py: Double,
                              cx: Double, cy: Double,
                              forwardM: Double, sideM: Double,
                              headingRad: Double) -> Bool {
        let dx = px - cx, dy = py - cy
        let fwd   = dx * sin(headingRad) + dy * cos(headingRad)
        let right = dx * cos(headingRad) - dy * sin(headingRad)
        return abs(fwd) <= forwardM && abs(right) <= sideM
    }

    /// The 4 corner vertices of an OBB rectangle in flat-Earth metres.
    private func rectVerts(cx: Double, cy: Double,
                            forwardM: Double, sideM: Double,
                            headingRad: Double) -> [(Double, Double)] {
        let sinH = sin(headingRad), cosH = cos(headingRad)
        return [
            (cx + forwardM * sinH + sideM * cosH, cy + forwardM * cosH - sideM * sinH),
            (cx + forwardM * sinH - sideM * cosH, cy + forwardM * cosH + sideM * sinH),
            (cx - forwardM * sinH - sideM * cosH, cy - forwardM * cosH + sideM * sinH),
            (cx - forwardM * sinH + sideM * cosH, cy - forwardM * cosH - sideM * sinH),
        ]
    }

    /// True if two OBB rectangles overlap (centre + vertex containment tests).
    private func rectsOverlap(cx1: Double, cy1: Double, f1: Double, s1: Double, h1: Double,
                               cx2: Double, cy2: Double, f2: Double, s2: Double, h2: Double) -> Bool {
        if pointInRect(px: cx2, py: cy2, cx: cx1, cy: cy1, forwardM: f1, sideM: s1, headingRad: h1) { return true }
        if pointInRect(px: cx1, py: cy1, cx: cx2, cy: cy2, forwardM: f2, sideM: s2, headingRad: h2) { return true }
        for (vx, vy) in rectVerts(cx: cx1, cy: cy1, forwardM: f1, sideM: s1, headingRad: h1) {
            if pointInRect(px: vx, py: vy, cx: cx2, cy: cy2, forwardM: f2, sideM: s2, headingRad: h2) { return true }
        }
        for (vx, vy) in rectVerts(cx: cx2, cy: cy2, forwardM: f2, sideM: s2, headingRad: h2) {
            if pointInRect(px: vx, py: vy, cx: cx1, cy: cy1, forwardM: f1, sideM: s1, headingRad: h1) { return true }
        }
        return false
    }

    /// True if an OBB rectangle and a diamond overlap.
    private func rectDiamondOverlap(rx: Double, ry: Double, rf: Double, rs: Double, rh: Double,
                                     dx: Double, dy: Double, df: Double, ds: Double, dh: Double) -> Bool {
        if pointInDiamond(px: rx, py: ry, cx: dx, cy: dy, forwardM: df, sideM: ds, headingRad: dh) { return true }
        if pointInRect(px: dx, py: dy, cx: rx, cy: ry, forwardM: rf, sideM: rs, headingRad: rh)    { return true }
        for (vx, vy) in rectVerts(cx: rx, cy: ry, forwardM: rf, sideM: rs, headingRad: rh) {
            if pointInDiamond(px: vx, py: vy, cx: dx, cy: dy, forwardM: df, sideM: ds, headingRad: dh) { return true }
        }
        for (vx, vy) in diamondVerts(cx: dx, cy: dy, forwardM: df, sideM: ds, headingRad: dh) {
            if pointInRect(px: vx, py: vy, cx: rx, cy: ry, forwardM: rf, sideM: rs, headingRad: rh) { return true }
        }
        return false
    }

    /// Checks every aircraft against every zone polygon.
    /// Altitude-independent — zone colliders extend from ground to infinity.
    ///
    /// Two levels:
    ///  • Collider ring touches zone edge → `zoneConflictIDs` (datablock blinks red)
    ///  • Aircraft body (position) enters polygon → aircraft is destroyed and removed
    private func detectZoneConflicts() {
        let shapes = zoneShapes()
        var conflicts = Set<UUID>()
        var toDestroy = Set<UUID>()

        for ac in aircraft {
            if shapes.contains(where: { polygonContains($0.coordinates, point: ac.position) }) {
                toDestroy.insert(ac.id)
            } else {
                let thresholdM = ac.colliderRadiusNM * 1852.0
                let touchesBoundary = shapes.contains { shape in
                    let coords = shape.coordinates
                    guard coords.count >= 2 else { return false }
                    for i in 0..<coords.count {
                        let a = coords[i], b = coords[(i + 1) % coords.count]
                        if distanceToSegmentMeters(point: ac.position, segA: a, segB: b) < thresholdM {
                            return true
                        }
                    }
                    return false
                }
                if touchesBoundary { conflicts.insert(ac.id) }
            }
        }

        // Destroy aircraft whose body entered a zone — remove from map and hangar.
        if !toDestroy.isEmpty {
            aircraft.removeAll { toDestroy.contains($0.id) }
            traffic.removeAll  { toDestroy.contains($0.id) }
            conflicts.subtract(toDestroy)
        }

        if conflicts != zoneConflictIDs { zoneConflictIDs = conflicts }
    }

    private let fixColliderRadiusNM = 1.0   // HOLDING circle radius — matches 20pt icon at zoom 8.8
    private let fixColliderSizeNM   = 1.0   // WAYPOINT/other triangle: NM from centre to vertex

    /// Checks every aircraft position against every fix collider.
    /// HOLDING fixes use a circular collider; all others use a north-pointing equilateral triangle.
    private func detectFixConflicts() {
        var conflicts = Set<UUID>()
        for ac in aircraft {
            for fix in fixes {
                guard let lat = fix.latitude, let lon = fix.longitude else { continue }
                let fixPos = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                if fix.type?.uppercased() == "HOLDING" {
                    if Geo.distanceMeters(from: ac.position, to: fixPos) < fixColliderRadiusNM * 1852 {
                        conflicts.insert(ac.id)
                    }
                } else {
                    if pointInFixTriangle(point: ac.position, center: fixPos,
                                         sizeM: fixColliderSizeNM * 1852) {
                        conflicts.insert(ac.id)
                    }
                }
            }
        }
        if conflicts != fixConflictIDs { fixConflictIDs = conflicts }
    }

    /// Ray-cast point-in-equilateral-triangle: north-pointing, vertices at `sizeM` from centre.
    private func pointInFixTriangle(point: CLLocationCoordinate2D,
                                     center: CLLocationCoordinate2D,
                                     sizeM: Double) -> Bool {
        let p = flatXY(origin: center, target: point)
        let v0 = (x: 0.0,              y: sizeM)          // north tip
        let v1 = (x:  sizeM * 0.866,   y: -sizeM * 0.5)  // bottom-right
        let v2 = (x: -sizeM * 0.866,   y: -sizeM * 0.5)  // bottom-left
        func cross(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double),
                   _ c: (x: Double, y: Double)) -> Double {
            (a.x - c.x) * (b.y - c.y) - (b.x - c.x) * (a.y - c.y)
        }
        let d1 = cross(p, v0, v1), d2 = cross(p, v1, v2), d3 = cross(p, v2, v0)
        return !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0))
    }

    /// Minimum distance (metres) from `point` to the line segment [segA, segB].
    /// Uses a flat-Earth projection centred on segA — accurate enough for radar scales.
    private func distanceToSegmentMeters(
        point: CLLocationCoordinate2D,
        segA: CLLocationCoordinate2D,
        segB: CLLocationCoordinate2D
    ) -> Double {
        let p  = flatXY(origin: segA, target: point)
        let ab = flatXY(origin: segA, target: segB)
        let lenSq = ab.x * ab.x + ab.y * ab.y
        guard lenSq > 0 else { return hypot(p.x, p.y) }
        let t = max(0, min(1, (p.x * ab.x + p.y * ab.y) / lenSq))
        return hypot(p.x - ab.x * t, p.y - ab.y * t)
    }

    /// Flat-Earth XY offset (metres) from `origin` to `target`.
    private func flatXY(origin: CLLocationCoordinate2D,
                        target: CLLocationCoordinate2D) -> (x: Double, y: Double) {
        let R = 6_371_000.0
        let dLat = (target.latitude  - origin.latitude)  * .pi / 180
        let dLon = (target.longitude - origin.longitude) * .pi / 180
        let meanLat = (origin.latitude + target.latitude) / 2 * .pi / 180
        return (x: dLon * cos(meanLat) * R, y: dLat * R)
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
        var position: CLLocationCoordinate2D = center
        var heading: Double = 0

        // Retry up to 20 times to find a spawn point outside every zone.
        for _ in 0..<20 {
            let candidate: CLLocationCoordinate2D
            let candidateHeading: Double

            if category == .arrival, let radial = randomVORRadial() {
                let spawnDistance = min(70 * Distance.metersPerNauticalMile, radial.lengthMeters)
                candidate = Geo.offset(from: radial.origin,
                                       distanceMeters: spawnDistance,
                                       bearingDegrees: radial.angle)
                candidateHeading = Geo.bearing(from: candidate, to: center)
            } else {
                let spawnBearing = Double.random(in: 0..<360)
                let rangeNM = Double.random(in: 60..<70)
                candidate = Geo.offset(from: center,
                                       distanceMeters: rangeNM * Distance.metersPerNauticalMile,
                                       bearingDegrees: spawnBearing)
                let inbound = (spawnBearing + 180).truncatingRemainder(dividingBy: 360)
                candidateHeading = (inbound + Double.random(in: -40...40) + 360)
                    .truncatingRemainder(dividingBy: 360)
            }

            position = candidate
            heading  = candidateHeading
            if !isInsideAnyZone(candidate) { break }
        }

        var aircraft = Aircraft(
            callsign: makeCallsign(),
            position: position,
            headingDegrees: heading
        )
        aircraft.category = category
        aircraft.aircraftType = aircraftTypes.randomElement()?.icaoCode

        // Pre-populate 6 history dots so the tail is visible from the moment
        // the aircraft appears. Dots are spaced by the same distance the aircraft
        // travels between two history samples (speed × sampleInterval).
        let sampleDistMeters = aircraft.speedKnots * 1852.0 / 3600.0
                               * Double(historySampleTicks) * tickInterval
        let backBearing = (heading + 180).truncatingRemainder(dividingBy: 360)
        for i in stride(from: 6, through: 1, by: -1) {
            aircraft.history.append(
                Geo.offset(from: position,
                           distanceMeters: Double(i) * sampleDistMeters,
                           bearingDegrees: backBearing)
            )
        }

        return aircraft
    }

    /// True if `point` is inside any zone polygon (ray-casting, flat-Earth).
    private func isInsideAnyZone(_ point: CLLocationCoordinate2D) -> Bool {
        zoneShapes().contains { polygonContains($0.coordinates, point: point) }
    }

    /// Standard ray-casting point-in-polygon using lat/lon as a 2-D plane.
    private func polygonContains(_ polygon: [CLLocationCoordinate2D],
                                  point: CLLocationCoordinate2D) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let xi = polygon[i].longitude, yi = polygon[i].latitude
            let xj = polygon[j].longitude, yj = polygon[j].latitude
            let crossesY = (yi > point.latitude) != (yj > point.latitude)
            let xIntersect = (xj - xi) * (point.latitude - yi) / (yj - yi) + xi
            if crossesY && point.longitude < xIntersect { inside = !inside }
            j = i
        }
        return inside
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
