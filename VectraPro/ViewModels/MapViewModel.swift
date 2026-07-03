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
        "Radials": true, "Fixes": true, "Fixes Names": true, "Zone": true, "Holding": true,
        "Trail": true
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
    private let historySampleTicks = 3      // sample a trail point every N ticks
    private let maxHistoryPoints = 500      // ~25 min of trail at 3-second sampling

    private let physics   = AircraftPhysics.shared
    private let collision = AircraftCollisionDetector.shared
    private let spawner   = AircraftSpawner.shared

    /// Context bundle passed to the simulator for all spawn calls.
    private var spawnContext: SpawnContext {
        SpawnContext(center: center, zoneShapes: zoneShapes(), fixes: fixes,
                     airlines: airlines, aircraftTypes: aircraftTypes, runways: runways,
                     historySampleTicks: historySampleTicks, tickInterval: tickInterval)
    }

    // MARK: - Distance measurement

    enum MeasurementAnchor {
        case fixed(CLLocationCoordinate2D)
        case aircraft(UUID)
    }

    @Published private(set) var isDistanceMeasuring = false
    private var measurementAnchorA: MeasurementAnchor?
    private var measurementAnchorB: MeasurementAnchor?

    var measurementPositionA: CLLocationCoordinate2D? { measurementAnchorA.flatMap { resolved($0) } }
    var measurementPositionB: CLLocationCoordinate2D? { measurementAnchorB.flatMap { resolved($0) } }

    private func resolved(_ anchor: MeasurementAnchor) -> CLLocationCoordinate2D? {
        switch anchor {
        case .fixed(let c):    return c
        case .aircraft(let id): return aircraft.first { $0.id == id }?.position
        }
    }

    func toggleDistanceMeasurement() {
        isDistanceMeasuring.toggle()
        if !isDistanceMeasuring { measurementAnchorA = nil; measurementAnchorB = nil }
    }

    func addMeasurementAnchor(_ anchor: MeasurementAnchor) {
        if measurementAnchorA == nil {
            measurementAnchorA = anchor
        } else if measurementAnchorB == nil {
            measurementAnchorB = anchor
        } else {
            measurementAnchorA = nil      // 3rd click → discard both, restart cycle
            measurementAnchorB = nil
        }
        objectWillChange.send()
    }

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

    /// The aircraft the controller has selected — keyboard commands apply to this one.
    @Published private(set) var selectedAircraftID: UUID? = nil

    func selectAircraft(_ id: UUID?) { selectedAircraftID = id }

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
        aircraft = [spawner.makeRandomAircraft(context: spawnContext)]
    }

    // MARK: - Voice commands

    /// Entry point for a transcribed command — parsed & applied centrally.
    func handleVoiceCommand(_ transcript: String) {
        commandController.process(transcript)
    }

    /// Apply parsed commands to the selected aircraft.
    /// Routes all audio feedback through CommandFeedbackManager.
    func apply(_ commands: [AircraftCommand]) {
        guard let id = selectedAircraftID,
              let i = aircraft.firstIndex(where: { $0.id == id }) else {
            CommandFeedbackManager.shared.aircraftNotFound()
            return
        }
        physics.apply(commands, to: &aircraft[i])
        CommandFeedbackManager.shared.commandAccepted(callsign: aircraft[i].callsign, commands: commands)
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

    /// Wipes all live state when leaving the radar screen so there is no stale
    /// flash if the user re-enters. applyExercise() will be called again before
    /// onAppear fires, so exercise config (fixes, zones, etc.) is safe to clear.
    func clearOnExit() {
        stopSimulation()
        tickCount = 0
        aircraft = []
        traffic  = []
        spawners = []
        selectedAircraftID   = nil
        yellowConflictIDs    = []
        redConflictIDs       = []
        zoneConflictIDs      = []
        fixConflictIDs       = []
        blinkState           = false
        isDrawing            = false
        pendingStart         = nil
        isDistanceMeasuring  = false
        measurementAnchorA   = nil
        measurementAnchorB   = nil
        // Clear exercise config — applyExercise() will repopulate before next reset().
        exerciseRunways      = nil
        exerciseApproaches   = nil
        fixes                = []
        zones                = []
        obstructions         = []
        airlines             = []
        aircraftTypes        = []
        freqDeparture        = nil
        freqArrival          = nil
        freqEnroute          = nil
        isMultiMode          = false
        airspaceCapacity     = 1
        aircraftSpawningCount = 1
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
        aircraft = initialCategories().map { spawner.makeRandomAircraft(context: spawnContext, category: $0) }
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

    private func tick() {
        tickCount += 1
        advanceSpawners()

        for index in aircraft.indices {
            physics.stepPhysics(&aircraft[index], dt: tickInterval)
            if tickCount % historySampleTicks == 0 {
                aircraft[index].history.append(aircraft[index].position)
                if aircraft[index].history.count > maxHistoryPoints {
                    aircraft[index].history.removeFirst()
                }
            }
        }

        // Aircraft-to-aircraft collisions.
        let acResult = collision.detectConflicts(in: aircraft)
        if !acResult.destroyed.isEmpty {
            if let sel = selectedAircraftID, acResult.destroyed.contains(sel) { selectedAircraftID = nil }
            aircraft.removeAll { acResult.destroyed.contains($0.id) }
            traffic.removeAll  { acResult.destroyed.contains($0.id) }
        }
        let yellows = acResult.yellows.subtracting(acResult.destroyed)
        let reds    = acResult.reds.subtracting(acResult.destroyed)
        if yellows != yellowConflictIDs { yellowConflictIDs = yellows }
        if reds    != redConflictIDs    { redConflictIDs    = reds    }

        // Zone boundary collisions.
        let zoneResult = collision.detectZoneConflicts(aircraft: aircraft, zoneShapes: zoneShapes())
        if !zoneResult.destroyed.isEmpty {
            if let sel = selectedAircraftID, zoneResult.destroyed.contains(sel) { selectedAircraftID = nil }
            aircraft.removeAll { zoneResult.destroyed.contains($0.id) }
            traffic.removeAll  { zoneResult.destroyed.contains($0.id) }
        }
        let zoneWarnings = zoneResult.warnings.subtracting(zoneResult.destroyed)
        if zoneWarnings != zoneConflictIDs { zoneConflictIDs = zoneWarnings }

        // Fix collisions.
        let fixConflicts = collision.detectFixConflicts(aircraft: aircraft, fixes: fixes)
        if fixConflicts != fixConflictIDs { fixConflictIDs = fixConflicts }

        blinkState.toggle()
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
                traffic.append(spawner.makeListAircraft(context: spawnContext, category: spawners[i].category))
                spawners[i].countdown += interval

            case .random(let remaining):
                guard remaining > 0 else {
                    spawners[i].countdown = .infinity   // quota done — stop
                    continue
                }
                traffic.append(spawner.makeListAircraft(context: spawnContext, category: spawners[i].category))
                let left = remaining - 1
                spawners[i].mode = .random(remaining: left)
                // Pick a fresh random interval for the next one (or stop).
                spawners[i].countdown = left > 0 ? (randomIntervals.randomElement() ?? 30) : .infinity
            }
        }
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
