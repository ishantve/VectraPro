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

    /// Aircraft drawn on the radar. Normally just the live targets; when the
    /// "Holding racetrack" layer is on, holding aircraft are shown too, orbiting
    /// their fix on the racetrack.
    var radarAircraft: [Aircraft] {
        guard layerOn("Holding racetrack") else { return aircraft }
        return aircraft + traffic.filter { $0.holdingName != nil }
    }

    /// Spawn-frequency config per category (from the exercise).
    private var freqDeparture: ExerciseDetail.FrequencyOfDeparture?
    private var freqArrival: ExerciseDetail.FrequencyOfArrival?
    private var freqEnroute: ExerciseDetail.FrequencyOfEnroute?

    /// How a category spawns: fixed interval up to quota (Custom), or random
    /// intervals up to a quota (Random). Both modes stop when `remaining` hits 0.
    private enum SpawnMode {
        case custom(interval: Double, remaining: Int)
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

    /// Countdown (seconds) until the next hangar-to-radar promotion.
    /// Stays `.infinity` when the airspace is already at capacity.
    private var radarPromotionCountdown: Double = .infinity
    private let promotionIntervals: [Double] = [15, 20, 30, 45, 60, 90]

    /// Fixed capacity weights: Arrival=40%, Departure=30%, Enroute=30%.
    private let categoryWeights: [FlightCategory: Double] = [
        .arrival: 40, .departure: 30, .enroute: 30
    ]

    /// Splits `total` across `categories` by their 40/30/30 weights,
    /// renormalised to whichever categories are active.
    /// The returned array always sums to exactly `total`.
    private func weightedSplit(total: Int, categories: [FlightCategory]) -> [Int] {
        guard total > 0, !categories.isEmpty else { return Array(repeating: 0, count: categories.count) }
        let weights = categories.map { categoryWeights[$0] ?? 1.0 }
        let totalWeight = weights.reduce(0, +)
        var shares = weights.map { Int((Double(total) * $0 / totalWeight).rounded()) }
        // Correct rounding by adjusting the largest share so sum == total.
        let diff = total - shares.reduce(0, +)
        if diff != 0, let idx = shares.indices.max(by: { shares[$0] < shares[$1] }) {
            shares[idx] += diff
        }
        return shares
    }

    /// Whether a category is active (Custom or Random). "None" or missing → inactive.
    /// Used by the UI to hide hangar-list sections for disabled categories.
    var isArrivalActive:   Bool { isActiveType(freqArrival?.type)   }
    var isDepartureActive: Bool { isActiveType(freqDeparture?.type) }
    var isEnrouteActive:   Bool { isActiveType(freqEnroute?.type)   }

    /// Radial lines for the exercise's VOR fixes (empty when none).
    func fixRadialLines() -> [MapLine] {
        FixRadialRenderer.lines(fixes: fixes)
    }

    /// Label positions / names / bearings for named VOR radials.
    func fixRadialLabels() -> [FixRadialRenderer.RadialLabel] {
        FixRadialRenderer.labels(fixes: fixes, center: center)
    }

    /// Polygon shapes (border + fill + label) for the exercise's airspace zones.
    /// Result is cached and only rebuilt when `zones` changes — called multiple
    /// times per tick from collision detection and spawn context.
    private var _cachedZoneShapes: [ZoneShape] = []
    private var _zoneShapesDirty = true

    func zoneShapes() -> [ZoneShape] {
        if _zoneShapesDirty {
            _cachedZoneShapes = ZoneRenderer.shapes(zones: zones)
            _zoneShapesDirty = false
        }
        return _cachedZoneShapes
    }

    /// Waypoint-type fixes, shown as triangle icons on the radar.
    var waypointFixes: [ExerciseDetail.Fix] {
        fixes.filter { $0.type?.uppercased() == "WAYPOINT" }
    }

    /// Holding-type fixes, shown as the holding icon on the radar.
    var holdingFixes: [ExerciseDetail.Fix] {
        fixes.filter { $0.type?.uppercased() == "HOLDING" }
    }

    /// Radius (metres) within which an inbound aircraft is captured by a hold.
    private let holdCaptureRadiusM = 1.0 * Distance.metersPerNauticalMile

    /// Public: coordinate of a holding fix by name (used by the map controller
    /// to draw the racetrack).
    func holdingFixPosition(named name: String) -> CLLocationCoordinate2D? {
        guard let fix = holdingFix(named: name) else { return nil }
        return coordinate(of: fix)
    }

    /// Find a holding fix by name, ignoring case, hyphens and spaces so spoken
    /// codes match hyphenated fix names ("re01" ↔ "RE-01", "vi95" ↔ "VI-95").
    private func holdingFix(named name: String) -> ExerciseDetail.Fix? {
        let target = canonicalFixName(name)
        return holdingFixes.first { canonicalFixName($0.fixName ?? "") == target }
    }

    /// Strips everything but letters and digits and lowercases — used for
    /// tolerant fix-name matching.
    private func canonicalFixName(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func coordinate(of fix: ExerciseDetail.Fix) -> CLLocationCoordinate2D? {
        guard let lat = fix.latitude, let lon = fix.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Continuously steer an aircraft's heading toward its commanded hold fix.
    private func steerTowardHold(_ aircraft: inout Aircraft) {
        guard let name = aircraft.holdingTargetName,
              let fix = holdingFix(named: name),
              let fixPos = coordinate(of: fix) else { return }
        aircraft.turnDirection = nil
        aircraft.targetHeading = Geo.bearing(from: aircraft.position, to: fixPos)
    }

    /// Move any aircraft that reached its commanded hold fix off the radar and
    /// into the holding hangar (as hangar traffic tagged with the fix name).
    private func captureAircraftAtHold() {
        var capturedIDs = Set<UUID>()
        for index in aircraft.indices {
            guard let name = aircraft[index].holdingTargetName,
                  let fix = holdingFix(named: name),
                  let fixPos = coordinate(of: fix) else { continue }
            // Capture as soon as the NOSE reaches the fix collider (not the body).
            let ac0 = aircraft[index]
            let noseReachM = (ac0.noseOffsetNM + ac0.noseForwardNM) * Distance.metersPerNauticalMile
            let nose = Geo.offset(from: ac0.position,
                                  distanceMeters: noseReachM,
                                  bearingDegrees: ac0.headingDegrees)
            guard Geo.distanceMeters(from: nose, to: fixPos) < holdCaptureRadiusM
            else { continue }

            var ac = aircraft[index]
            ac.holdingName          = fix.fixName   // canonical name → matches hangar filter
            ac.holdingTargetName    = nil
            ac.holdingInboundCourse = ac.headingDegrees   // course it arrived on = inbound leg
            ac.holdingProgress      = 0                   // start at the fix, entering turn 1
            ac.targetHeading        = nil
            ac.turnDirection        = nil
            ac.history              = []
            traffic.append(ac)
            capturedIDs.insert(ac.id)
        }
        guard !capturedIDs.isEmpty else { return }
        if let sel = selectedAircraftID, capturedIDs.contains(sel) { selectedAircraftID = nil }
        aircraft.removeAll { capturedIDs.contains($0.id) }
        // Free radar slot → refill soon.
        if aircraft.count < airspaceCapacity {
            let fastRefill = promotionIntervals.prefix(3).randomElement() ?? 15
            radarPromotionCountdown = min(radarPromotionCountdown, fastRefill)
        }
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
        _zoneShapesDirty = true

        #if DEBUG
        let holdings = detail.fixes.filter { $0.type?.uppercased() == "HOLDING" }
        print("📡 HOLDING FIXES FROM API — \(holdings.count) found")
        for f in holdings {
            print("""
              • fixId : \(f.fixId ?? "-")
                name  : \(f.fixName ?? "-")
                type  : \(f.type ?? "-")   fixType: \(f.fixType ?? "-")
                lat   : \(f.latitude.map { String($0) } ?? "-")
                lon   : \(f.longitude.map { String($0) } ?? "-")
                radials: \(f.radials?.count ?? 0)
            """)
        }
        #endif

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
        exerciseName = detail.exerciseName
        // gameEndTime arrives in minutes from the API.
        exerciseDurationSeconds = (detail.gameEndTime ?? 0) * 60

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
            // Show a localizer only when it's set to display AND is active.
            if strips[0].displayLocalizer == true && strips[0].activeLocalizer == true {
                enabled.insert(ApproachID(runwayID: runway.id, side: .a))
            }
            if strips[1].displayLocalizer == true && strips[1].activeLocalizer == true {
                enabled.insert(ApproachID(runwayID: runway.id, side: .b))
            }
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

    // MARK: - Exercise timer

    /// Display name of the active exercise (set by applyExercise).
    @Published private(set) var exerciseName: String = ""
    /// Seconds elapsed since the exercise started (counts up from 0).
    @Published private(set) var elapsedSeconds: Int = 0
    /// Total exercise duration in seconds (0 = unlimited).
    @Published private(set) var exerciseDurationSeconds: Int = 0
    /// True once the timer reaches the full duration; triggers the summary popup.
    @Published private(set) var isExerciseFinished = false

    // MARK: - Aircraft

    @Published private(set) var aircraft: [Aircraft] = []

    private var simulationTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private let tickInterval = 1.0          // seconds

    // MARK: - Simulation speed (fast-forward)

    /// Available fast-forward multipliers.
    static let speedOptions = [1, 2, 3, 5, 10, 15, 20, 30]
    /// Current simulation speed multiplier (1× = real time).
    @Published private(set) var simulationSpeed = 1

    /// Step up to the next faster multiplier.
    func increaseSpeed() {
        guard let i = Self.speedOptions.firstIndex(of: simulationSpeed),
              i + 1 < Self.speedOptions.count else { return }
        simulationSpeed = Self.speedOptions[i + 1]
        restartTimerIfRunning()
    }

    /// Step down to the previous slower multiplier.
    func decreaseSpeed() {
        guard let i = Self.speedOptions.firstIndex(of: simulationSpeed),
              i - 1 >= 0 else { return }
        simulationSpeed = Self.speedOptions[i - 1]
        restartTimerIfRunning()
    }

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
    /// Aircraft IDs currently in destroyed state — shown with destroyed icon for 1.5 s before removal.
    @Published private(set) var destroyedAircraftIDs: Set<UUID> = []

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
        guard let id = selectedAircraftID else {
            CommandFeedbackManager.shared.aircraftNotFound()
            return
        }
        applyCommands(commands, toAircraftWithID: id)
    }

    /// Central command application. Radar aircraft get the command directly.
    /// A holding aircraft keeps holding for speed/altitude clearances, but is
    /// released back onto the radar for a vectoring / direct / hold command.
    private func applyCommands(_ commands: [AircraftCommand], toAircraftWithID id: UUID) {
        // Live radar aircraft.
        if let i = aircraft.firstIndex(where: { $0.id == id }) {
            physics.apply(commands, to: &aircraft[i])
            CommandFeedbackManager.shared.commandAccepted(callsign: aircraft[i].callsign, commands: commands)
            return
        }
        // Holding aircraft (in the hangar).
        if let ti = traffic.firstIndex(where: { $0.id == id && $0.holdingName != nil }) {
            if commandsLeaveHold(commands) {
                // Vector / clear out of the hold: release onto the radar.
                var ac = traffic.remove(at: ti)
                ac.holdingName          = nil
                ac.holdingTargetName    = nil
                ac.holdingInboundCourse = nil
                ac.holdingProgress      = 0
                ac.history              = []
                aircraft.append(ac)
                let last = aircraft.count - 1
                physics.apply(commands, to: &aircraft[last])
                CommandFeedbackManager.shared.commandAccepted(callsign: aircraft[last].callsign, commands: commands)
            } else {
                // Speed / altitude clearance: obey while remaining in the hold.
                physics.apply(commands, to: &traffic[ti])
                CommandFeedbackManager.shared.commandAccepted(callsign: traffic[ti].callsign, commands: commands)
            }
            return
        }
        CommandFeedbackManager.shared.aircraftNotFound()
    }

    /// Commands that take an aircraft OUT of a holding pattern (vectoring,
    /// resume navigation, or a new hold). Speed/altitude clearances keep it in.
    private func commandsLeaveHold(_ commands: [AircraftCommand]) -> Bool {
        commands.contains { cmd in
            switch cmd {
            case .heading, .headingTurn, .relativeTurn, .presentHeading, .hold: return true
            case .speed, .minSpeed, .maxSpeed, .flightLevel, .altitudeBlock:    return false
            }
        }
    }

    deinit {
        simulationTimer?.invalidate()
    }

    // MARK: - Simulation

    func startSimulation() {
        guard simulationTimer == nil else { return }
        scheduleTimer()
    }

    func stopSimulation() {
        simulationTimer?.invalidate()
        simulationTimer = nil
    }

    /// (Re)creates the timer at the current speed. Fast-forward fires the timer
    /// more often (interval = tickInterval / speed) and advances ONE sim-second
    /// per fire, so the clock counts up smoothly instead of jumping by N.
    private func scheduleTimer() {
        simulationTimer?.invalidate()
        let interval = tickInterval / Double(max(1, simulationSpeed))
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        simulationTimer = timer
    }

    /// Restart the timer with a new cadence when the speed changes mid-run.
    private func restartTimerIfRunning() {
        guard simulationTimer != nil else { return }
        scheduleTimer()
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
        destroyedAircraftIDs = []
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
        _zoneShapesDirty     = true
        airlines             = []
        aircraftTypes        = []
        freqDeparture        = nil
        freqArrival          = nil
        freqEnroute          = nil
        isMultiMode          = false
        airspaceCapacity     = 1
        aircraftSpawningCount = 1
        radarPromotionCountdown = .infinity
        exerciseName             = ""
        elapsedSeconds           = 0
        exerciseDurationSeconds  = 0
        isExerciseFinished       = false
        simulationSpeed          = 1
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
        elapsedSeconds      = 0
        isExerciseFinished  = false
        spawner.resetRadialCycle(fixes: fixes)
        aircraft = initialCategories().map { spawner.makeRandomAircraft(context: spawnContext, category: $0) }
        resetTraffic()
        // Start filling toward capacity if initial spawn didn't reach it.
        radarPromotionCountdown = aircraft.count < airspaceCapacity
            ? (promotionIntervals.randomElement() ?? 30)
            : .infinity
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
        let split = weightedSplit(total: count, categories: cats)
        return zip(cats, split).flatMap { Array(repeating: $0.0, count: $0.1) }
    }

    /// Clear the hangar lists and rebuild the spawners from the exercise.
    /// Capacity is divided 40% Arrival / 30% Departure / 30% Enroute among
    /// the active categories; "none" (or missing) categories get no spawner.
    private func resetTraffic() {
        traffic = []
        spawners = []

        let configs: [(category: FlightCategory, type: String?, flights: Int?, minutes: Int?)] = [
            (.arrival,   freqArrival?.type,   freqArrival?.arrivalFlights,     freqArrival?.arrivalFlightsTimeValue),
            (.departure, freqDeparture?.type, freqDeparture?.departureFlights, freqDeparture?.departureFlightsTimeValue),
            (.enroute,   freqEnroute?.type,   freqEnroute?.enrouteFlights,     freqEnroute?.enrouteFlightsTimeValue)
        ]

        // Per-category quota: 40/30/30 weighted split across all active categories.
        let activeCats = configs.filter { isActiveType($0.type) }.map(\.category)
        let quotas     = weightedSplit(total: airspaceCapacity, categories: activeCats)
        let quotaMap   = Dictionary(uniqueKeysWithValues: zip(activeCats, quotas))

        for config in configs {
            guard let quota = quotaMap[config.category], quota > 0 else { continue }
            switch config.type?.lowercased() {
            case "custom":
                guard let flights = config.flights, flights > 0,
                      let minutes = config.minutes, minutes > 0 else { continue }
                let interval = Double(minutes) * 60.0 / Double(flights)
                spawners.append((config.category, .custom(interval: interval, remaining: quota), interval))
            case "random":
                spawners.append((config.category, .random(remaining: quota), randomIntervals.randomElement() ?? 30))
            default:
                continue   // "none" / missing → no spawner
            }
        }

        // Seed one departure aircraft into the hangar immediately so the
        // controller always has something to clear for takeoff at exercise start.
        if spawners.contains(where: { $0.category == .departure }) {
            traffic.append(spawner.makeListAircraft(context: spawnContext, category: .departure))
        }
    }

    /// Timer callback. Fires every `tickInterval / speed` real seconds and
    /// advances exactly one sim-second, so the clock counts up smoothly (fast,
    /// but without skipping numbers). Blink stays on a ~1 s real-time cadence.
    private func tick() {
        guard !isExerciseFinished else { return }
        advanceStep()
        if tickCount % max(1, simulationSpeed) == 0 { blinkState.toggle() }
    }

    private func advanceStep() {
        tickCount += 1
        advanceSpawners()
        advanceRadarPromotion()

        for index in aircraft.indices {
            guard !destroyedAircraftIDs.contains(aircraft[index].id) else { continue }
            // Auto-turn toward a commanded holding fix (proceed direct).
            steerTowardHold(&aircraft[index])
            physics.stepPhysics(&aircraft[index], dt: tickInterval)
            if tickCount % historySampleTicks == 0 {
                aircraft[index].history.append(aircraft[index].position)
                if aircraft[index].history.count > maxHistoryPoints {
                    aircraft[index].history.removeFirst()
                }
            }
        }

        // Holding capture: aircraft that reached their commanded hold fix leave
        // the radar and enter the holding hangar.
        captureAircraftAtHold()

        // Fly the holding racetracks. This runs every tick regardless of the
        // layer's visibility, so an aircraft keeps orbiting while hidden and
        // reappears at its up-to-date position when the layer is turned back on.
        // Only the drawing (radarAircraft) is gated by the layer toggle.
        for i in traffic.indices where traffic[i].holdingName != nil {
            guard let ic = traffic[i].holdingInboundCourse,
                  let fixPos = holdingFixPosition(named: traffic[i].holdingName ?? "") else { continue }
            // Apply any speed/altitude clearance while holding. The pattern is
            // sized from the CURRENT speed (so the turn radius grows/shrinks
            // realistically), and progress is a fraction, so speed changes —
            // which converge gradually — morph the oval smoothly without jumps.
            physics.adjustSpeedAltitude(&traffic[i], dt: tickInterval)
            let track = HoldingRacetrack(fix: fixPos, inboundCourse: ic,
                                         speedKnots: traffic[i].speedKnots)
            let vmps  = traffic[i].speedKnots * Distance.metersPerNauticalMile / 3600
            let total = track.totalLength
            var prog  = traffic[i].holdingProgress + (vmps * tickInterval) / total
            prog = prog.truncatingRemainder(dividingBy: 1)
            traffic[i].holdingProgress = prog
            let s = track.sample(at: prog * total)
            traffic[i].position       = s.position
            traffic[i].headingDegrees = s.heading
            if tickCount % historySampleTicks == 0 {
                traffic[i].history.append(traffic[i].position)
                if traffic[i].history.count > maxHistoryPoints {
                    traffic[i].history.removeFirst()
                }
            }
        }

        // Aircraft-to-aircraft collisions.
        let acResult = collision.detectConflicts(in: aircraft)
        if !acResult.destroyed.isEmpty {
            let fresh = acResult.destroyed.subtracting(destroyedAircraftIDs)
            if !fresh.isEmpty {
                destroyedAircraftIDs.formUnion(fresh)
                if let sel = selectedAircraftID, fresh.contains(sel) { selectedAircraftID = nil }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self else { return }
                    self.aircraft.removeAll { fresh.contains($0.id) }
                    self.traffic.removeAll  { fresh.contains($0.id) }
                    self.destroyedAircraftIDs.subtract(fresh)
                }
            }
        }
        let yellows = acResult.yellows.subtracting(acResult.destroyed)
        let reds    = acResult.reds.subtracting(acResult.destroyed)
        if yellows != yellowConflictIDs { yellowConflictIDs = yellows }
        if reds    != redConflictIDs    { redConflictIDs    = reds    }

        // Zone boundary collisions.
        let zoneResult = collision.detectZoneConflicts(aircraft: aircraft, zoneShapes: zoneShapes())
        if !zoneResult.destroyed.isEmpty {
            let fresh = zoneResult.destroyed.subtracting(destroyedAircraftIDs)
            if !fresh.isEmpty {
                destroyedAircraftIDs.formUnion(fresh)
                if let sel = selectedAircraftID, fresh.contains(sel) { selectedAircraftID = nil }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self else { return }
                    self.aircraft.removeAll { fresh.contains($0.id) }
                    self.traffic.removeAll  { fresh.contains($0.id) }
                    self.destroyedAircraftIDs.subtract(fresh)
                }
            }
        }

        // After any destruction, arm a short-delay promotion so the slot refills quickly.
        if (!acResult.destroyed.isEmpty || !zoneResult.destroyed.isEmpty), aircraft.count < airspaceCapacity {
            let fastRefill = promotionIntervals.prefix(3).randomElement() ?? 15
            radarPromotionCountdown = min(radarPromotionCountdown, fastRefill)
        }
        let zoneWarnings = zoneResult.warnings.subtracting(zoneResult.destroyed)
        if zoneWarnings != zoneConflictIDs { zoneConflictIDs = zoneWarnings }

        // Fix collisions.
        let fixConflicts = collision.detectFixConflicts(aircraft: aircraft, fixes: fixes)
        if fixConflicts != fixConflictIDs { fixConflictIDs = fixConflicts }

        // Advance the exercise clock; finish when we reach the target duration.
        elapsedSeconds += 1
        if exerciseDurationSeconds > 0, elapsedSeconds >= exerciseDurationSeconds {
            isExerciseFinished = true
            stopSimulation()
        }
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
            case .custom(let interval, let remaining):
                guard remaining > 0 else { spawners[i].countdown = .infinity; continue }
                traffic.append(spawner.makeListAircraft(context: spawnContext, category: spawners[i].category))
                spawners[i].mode = .custom(interval: interval, remaining: remaining - 1)
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

    /// Counts down and promotes one hangar aircraft to the radar when the
    /// airspace has room. Rearms itself for the next promotion automatically.
    private func advanceRadarPromotion() {
        guard aircraft.count < airspaceCapacity else {
            radarPromotionCountdown = .infinity
            return
        }
        radarPromotionCountdown -= tickInterval
        guard radarPromotionCountdown <= 0 else { return }
        promoteFromHangar()
    }

    /// Moves one arrival or enroute aircraft from the hangar onto the radar.
    /// Falls back to a fresh spawn when the hangar has no eligible aircraft.
    private func promoteFromHangar() {
        let eligibleIndices = traffic.indices.filter {
            traffic[$0].holdingName == nil &&
            (traffic[$0].category == .arrival || traffic[$0].category == .enroute)
        }
        let category: FlightCategory
        if let idx = eligibleIndices.randomElement() {
            category = traffic[idx].category
            traffic.remove(at: idx)
        } else {
            category = Bool.random() ? .arrival : .enroute
        }
        aircraft.append(spawner.makeRandomAircraft(context: spawnContext, category: category))
        radarPromotionCountdown = aircraft.count < airspaceCapacity
            ? (promotionIntervals.randomElement() ?? 30)
            : .infinity
    }

    // MARK: - Departure clearance

    /// Moves a departure aircraft from the hangar to its assigned runway threshold
    /// and starts the takeoff ground roll.
    func clearForTakeoff(callsign: String) {
        guard let idx = traffic.firstIndex(where: {
            $0.callsign.uppercased() == callsign.uppercased() && $0.category == .departure
        }) else {
            CommandFeedbackManager.shared.aircraftNotFound()
            return
        }
        var ac = traffic[idx]
        let (threshold, heading) = departureThreshold(for: ac)

        ac.position           = threshold
        ac.headingDegrees     = heading
        ac.speedKnots         = 0
        ac.altitudeFeet       = 0
        ac.targetSpeedKnots   = Aircraft.defaultSpeedKnots
        ac.targetAltitudeFeet = 5000   // climb to FL050 after liftoff
        ac.takeoffState       = .groundRoll(runwayHeading: heading)
        ac.history            = []

        traffic.remove(at: idx)
        aircraft.append(ac)
        CommandFeedbackManager.shared.commandAccepted(callsign: ac.callsign, commands: [])
    }

    /// Resolves a departure callsign from an already-normalised voice transcript.
    func resolveDepartureCallsign(from normalizedText: String) -> String? {
        resolveCallsign(from: normalizedText,
                        among: traffic.filter { $0.category == .departure })
    }

    /// Resolves a live radar aircraft callsign from an already-normalised voice
    /// transcript. Holding aircraft (in the hangar) are included so they can be
    /// cleared/vectored by callsign.
    func resolveRadarCallsign(from normalizedText: String) -> String? {
        let candidates = aircraft + traffic.filter { $0.holdingName != nil }
        return resolveCallsign(from: normalizedText, among: candidates)
    }

    /// Applies commands to an aircraft found by callsign — no selection required.
    func applyToCallsign(_ callsign: String, commands: [AircraftCommand]) {
        guard let id = (aircraft + traffic).first(where: {
            $0.callsign.uppercased() == callsign.uppercased()
        })?.id else {
            CommandFeedbackManager.shared.aircraftNotFound()
            return
        }
        applyCommands(commands, toAircraftWithID: id)
    }

    /// Shared resolver: direct ICAO match → spoken airline name + flight number.
    private func resolveCallsign(from normalizedText: String,
                                 among candidates: [Aircraft]) -> String? {
        let text = normalizedText.lowercased()
        // 1. Direct match — "aic235" or spaced form "aca 29" both match callsign "ACA29".
        for ac in candidates {
            let cs = ac.callsign.lowercased()
            if text.contains(cs) { return ac.callsign }
            // Spoken callsigns often have a space between letter prefix and digits.
            let letters = String(cs.prefix(while: { $0.isLetter }))
            let digits  = String(cs.drop(while:  { $0.isLetter }))
            if !letters.isEmpty && !digits.isEmpty && text.contains("\(letters) \(digits)") {
                return ac.callsign
            }
        }
        // 2. Airline spoken name + flight number — e.g. "air india 235".
        for airline in airlines {
            guard let spoken = airline.callSign?.lowercased().trimmingCharacters(in: .whitespaces),
                  !spoken.isEmpty,
                  let icao = airline.icaoCode?.uppercased(), !icao.isEmpty,
                  let nameRange = text.range(of: spoken) else { continue }
            let after  = String(text[nameRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            let digits = String(after.prefix(while: { $0.isNumber || $0 == " " })
                                     .filter(\.isNumber).prefix(4))
            guard !digits.isEmpty else { continue }
            let candidate = icao + digits
            if candidates.contains(where: { $0.callsign.uppercased() == candidate }) {
                return candidate
            }
        }
        return nil
    }

    /// Returns the threshold coordinate and takeoff heading for an aircraft's
    /// assigned runway. Falls back to the first available runway, then the center.
    private func departureThreshold(for ac: Aircraft) -> (CLLocationCoordinate2D, Double) {
        for runway in runways {
            if runway.endA.designator == ac.assignedRunway {
                return (runway.endA.coordinate,
                        Geo.bearing(from: runway.endA.coordinate, to: runway.endB.coordinate))
            }
            if runway.endB.designator == ac.assignedRunway {
                return (runway.endB.coordinate,
                        Geo.bearing(from: runway.endB.coordinate, to: runway.endA.coordinate))
            }
        }
        if let rwy = runways.first {
            return (rwy.endA.coordinate,
                    Geo.bearing(from: rwy.endA.coordinate, to: rwy.endB.coordinate))
        }
        return (center, 0)
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
    /// aircraft so it stays attached as the aircraft moves. Handles both radar
    /// aircraft and holding aircraft (which live in the hangar `traffic` list).
    func setLabelOffset(for id: UUID, bearingDegrees: Double, distanceMeters: Double) {
        if let index = aircraft.firstIndex(where: { $0.id == id }) {
            aircraft[index].labelBearingDegrees = bearingDegrees
            aircraft[index].labelDistanceMeters = distanceMeters
        } else if let index = traffic.firstIndex(where: { $0.id == id }) {
            traffic[index].labelBearingDegrees = bearingDegrees
            traffic[index].labelDistanceMeters = distanceMeters
        }
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
