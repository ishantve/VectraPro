//
//  MapViewModel.swift
//  VectraPro
//
//  Drives the radar map: range rings, enabled runways, localizers, design.
//

import Combine
import ATCSimKit
import ATCTrafficKit
import GeoNavKit
import CoreLocation
import Foundation

final class MapViewModel: ObservableObject {

    // MARK: - Radar

    /// Radar center. Defaults to IGI; replaced by the started exercise's
    /// map location so the range rings draw around it.
    private(set) var center: CLLocationCoordinate2D = MapConfiguration.center
    /// Map-layer visibility (driven by the "Map Layers" menu toggles). Keyed by
    /// `RadarDisplayLayer.rawValue`; use the typed `layerOn`/`setLayer` accessors.
    @Published private(set) var layers: [String: Bool] = Dictionary(
        uniqueKeysWithValues: RadarDisplayLayer.allCases
            .filter { $0.defaultOn }
            .map { ($0.rawValue, true) }
    )

    func layerOn(_ layer: RadarDisplayLayer) -> Bool { layers[layer.rawValue] ?? false }

    /// Set a layer toggle, cascading to its dependent label layer (Fixes → Fixes
    /// Names, Radials → Radials Names) when the parent turns on or off.
    func setLayer(_ layer: RadarDisplayLayer, _ value: Bool) {
        layers[layer.rawValue] = value
        if let dependent = layer.dependentLayer {
            layers[dependent.rawValue] = value
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
        guard layerOn(.holdingRacetrack) else { return aircraft }
        return aircraft + traffic.filter { $0.holdingName != nil }
    }

    /// Spawn policy + schedules — decides *when* and *what* to spawn. This view
    /// model still owns the published collections and makes the aircraft; the
    /// orchestrator only computes decisions (see SpawnOrchestrator).
    private let spawn = SpawnOrchestrator()

    /// Aircraft identities from the exercise (airlines / types). Used across the
    /// command, sequencing and rendering paths, so they stay here rather than in
    /// the spawn policy.
    private var airlines: [ExerciseDetail.Airline] = []
    private var aircraftTypes: [ExerciseDetail.AircraftType] = []


    /// Whether a category is active (Custom or Random). "None" or missing → inactive.
    /// Used by the UI to hide hangar-list sections for disabled categories.
    var isArrivalActive:   Bool { spawn.isArrivalActive   }
    var isDepartureActive: Bool { spawn.isDepartureActive }
    var isEnrouteActive:   Bool { spawn.isEnrouteActive   }

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

    /// Holding-type fixes, shown as the holding icon on the radar (wire model,
    /// used by the renderers).
    var holdingFixes: [ExerciseDetail.Fix] {
        fixes.filter { $0.type?.uppercased() == "HOLDING" }
    }

    /// Holding fixes as ATCSimKit domain inputs, for the simulation services.
    private var holdingFixesDomain: [ATCSimKit.Fix] {
        holdingFixes.map(\.asDomain)
    }

    /// Every fix an aircraft may be routed direct to or asked to report — waypoints
    /// and VORs as well as holding fixes, since "proceed direct" and "report passing"
    /// are not limited to holds.
    var navigationFixesDomain: [ATCSimKit.Fix] {
        fixes.map(\.asDomain)
    }

    /// The aircraft answering to a callsign, radar or hangar.
    func aircraft(callsign: String) -> Aircraft? {
        (aircraft + traffic).first { $0.callsign.caseInsensitiveCompare(callsign) == .orderedSame }
    }

    /// Scene inputs for validation, shared by the command path and the report path.
    var validationContext: CommandValidator.Context {
        CommandValidator.Context(runways: runways,
                                 activeLocalizerRunways: activeLocalizerRunways,
                                 holdingFixes: holdingFixesDomain,
                                 navigationFixes: navigationFixesDomain)
    }

    /// Public: coordinate of a holding fix by name (used by the map controller
    /// to draw the racetrack).
    func holdingFixPosition(named name: String) -> CLLocationCoordinate2D? {
        FixLookup.position(named: name, in: holdingFixesDomain)
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

        spawn.configure(from: detail)

        // Aircraft identities (airlines / aircraft types) — used well beyond spawning.
        airlines = detail.airlines
        aircraftTypes = detail.aircrafts
        exerciseName = detail.exerciseName
        // gameEndTime arrives in minutes from the API.
        exerciseDurationSeconds = (detail.gameEndTime ?? 0) * 60

        let layout = ExerciseRunwayLayout(from: detail.runways)
        activeLocalizerRunways = layout.activeLocalizerRunways

        if layout.isEmpty {
            exerciseRunways = nil
            exerciseApproaches = nil
        } else {
            exerciseRunways = layout.runways
            exerciseApproaches = layout.enabledApproaches
            runways = layout.runways
            enabledApproaches = layout.enabledApproaches
        }

        detail.dumpToConsole(initialSpawnCount: spawn.initialSpawnCount())
    }

    // MARK: - Runways & approaches

    @Published private(set) var runways: [Runway] = []
    /// Canonical designators of runway ends whose localizer is active — only
    /// these can be intercepted.
    private var activeLocalizerRunways: Set<String> = []

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

    // Simulation collaborators — injected (default to the shared instances) so
    // MapViewModel can be exercised with test doubles instead of reaching into
    // globals internally.
    private let physics:   AircraftPhysics
    private let collision: AircraftCollisionDetector
    private let spawner:   AircraftSpawner

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
    /// Aircraft on final (localizer) that are closer than the required landing
    /// separation to the one ahead (small 10 NM · medium/heavy 8 NM).
    @Published private(set) var sequencingConflictIDs: Set<UUID> = []
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

    /// Where spoken and logged output goes. Named rather than reached for, so a
    /// test can hand over a spy — the real one talks to the device synthesiser.
    private let feedback: CommandFeedback
    /// Reports aircraft owe, evaluated each tick.
    private let reports: DeferredReportAnnouncing

    init(physics: AircraftPhysics? = nil,
         collision: AircraftCollisionDetector? = nil,
         spawner: AircraftSpawner? = nil,
         feedback: CommandFeedback? = nil,
         reports: DeferredReportAnnouncing? = nil) {
        self.physics   = physics ?? .shared
        self.collision = collision ?? .shared
        self.spawner   = spawner ?? .shared
        self.feedback  = feedback ?? CommandFeedbackManager.shared
        self.reports   = reports ?? DeferredReportCoordinator.shared
        aircraft = [self.spawner.makeRandomAircraft(context: spawnContext)]
    }

    // MARK: - Voice commands

    /// Entry point for a transcribed command — parsed & applied centrally.
    func handleVoiceCommand(_ transcript: String) {
        commandController.process(transcript)
    }

    /// Apply parsed commands to the selected aircraft.
    /// Routes all audio feedback through CommandFeedbackManager.
    func apply(_ commands: [AircraftCommand], readback: String? = nil) {
        guard let id = selectedAircraftID else {
            feedback.aircraftNotFound()
            return
        }
        applyCommands(commands, toAircraftWithID: id, readback: readback)
    }

    /// Callsign of the aircraft a keypad command would act on — needed to render
    /// its readback, which names the aircraft.
    var selectedCallsign: String? {
        guard let id = selectedAircraftID else { return nil }
        return (aircraft + traffic).first { $0.id == id }?.callsign
    }

    /// Central command application. Radar aircraft get the command directly.
    /// A holding aircraft keeps holding for speed/altitude clearances, but is
    /// released back onto the radar for a vectoring / direct / hold command.
    private func applyCommands(_ commands: [AircraftCommand],
                               toAircraftWithID id: UUID,
                               readback: String? = nil) {
        // Validate the whole utterance against the aircraft + scene before applying
        // anything (altitude/speed envelope, turn limits, hold-fix existence, and
        // the localizer-intercept checks). On failure, speak the reason and apply
        // nothing.
        if let ac = (aircraft + traffic).first(where: { $0.id == id }) {
            if case .rejected(let reason) = CommandValidator.validate(commands, for: ac,
                                                                       context: validationContext) {
                feedback.commandError(reason)
                return
            }
        }

        // Live radar aircraft.
        if let i = aircraft.firstIndex(where: { $0.id == id }) {
            physics.apply(commands, to: &aircraft[i])
            announce(readback, callsign: aircraft[i].callsign, commands: commands)
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
                announce(readback, callsign: aircraft[last].callsign, commands: commands)
            } else {
                // Speed / altitude clearance: obey while remaining in the hold.
                physics.apply(commands, to: &traffic[ti])
                announce(readback, callsign: traffic[ti].callsign, commands: commands)
            }
            return
        }
        feedback.aircraftNotFound()
    }

    /// Speaks the readback rendered from the template that was spoken.
    ///
    /// Nothing assembles a reply here any more. A missing readback means a command was
    /// applied without the vocabulary that describes it, which both input paths refuse
    /// outright — so it is a programming error rather than a case to paper over with
    /// English of our own.
    private func announce(_ readback: String?,
                          callsign: String,
                          commands: [AircraftCommand]) {
        guard let readback, !readback.isEmpty else {
            assertionFailure("applied \(commands.count) command(s) to \(callsign) with no readback")
            return
        }
        feedback.readback(readback)
    }

    /// Commands that take an aircraft OUT of a holding pattern (vectoring,
    /// resume navigation, or a new hold). Speed/altitude clearances keep it in.
    private func commandsLeaveHold(_ commands: [AircraftCommand]) -> Bool {
        commands.contains { cmd in
            switch cmd {
            case .heading, .headingTurn, .relativeTurn, .presentHeading, .stopTurn,
                 .hold, .proceedDirect, .interceptLocalizer, .goAround:
                return true
            case .speed, .minSpeed, .maxSpeed, .altitude, .altitudeBlock,
                 .stopClimb, .stopDescent, .squawk, .clearedForTakeoff:
                return false
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
        spawn.clear()
        selectedAircraftID   = nil
        yellowConflictIDs    = []
        redConflictIDs       = []
        zoneConflictIDs      = []
        fixConflictIDs       = []
        sequencingConflictIDs = []
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
        // Spawn one at a time so each new aircraft stays ≥15 NM from the rest.
        var spawned: [Aircraft] = []
        for category in spawn.initialRadarCategories() {
            let ac = spawner.makeRandomAircraft(context: spawnContext,
                                                category: category,
                                                existing: spawned.map(\.position))
            spawned.append(ac)
        }
        aircraft = spawned
        // Rebuild the hangar schedule and seed it: the orchestrator decides the
        // categories, this makes the aircraft.
        traffic = spawn.beginTraffic().map {
            spawner.makeListAircraft(context: spawnContext, category: $0)
        }
        // Fill toward capacity promptly if the initial spawn fell short of it.
        spawn.maintainCapacity(radarCount: aircraft.count)
        startSimulation()
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

        // Hangar spawns: the orchestrator says which categories are due; this makes
        // and files them. `listAircraft.count` is read once, as before.
        for category in spawn.dueHangarSpawns(by: tickInterval, listCount: listAircraft.count) {
            traffic.append(spawner.makeListAircraft(context: spawnContext, category: category))
        }

        // Radar promotion: the orchestrator decides whether to promote and which
        // hangar aircraft it consumes; this owns the collections and the spawn.
        if let promotion = spawn.radarPromotion(by: tickInterval,
                                                radarCount: aircraft.count,
                                                hangar: traffic) {
            if let id = promotion.vacatedHangarID { traffic.removeAll { $0.id == id } }
            aircraft.append(spawner.makeRandomAircraft(context: spawnContext,
                                                       category: promotion.category,
                                                       existing: aircraft.map(\.position)))
        }

        rollClearedDepartures()

        var landedIDs = Set<UUID>()
        for index in aircraft.indices {
            guard !destroyedAircraftIDs.contains(aircraft[index].id) else { continue }
            // Auto-turn toward a commanded holding fix (proceed direct).
            HoldingController.steer(&aircraft[index], fixes: holdingFixesDomain)
            // Direct routing to any fix — steered the same way, but the aircraft
            // passes the fix and carries on instead of entering a racetrack.
            DirectRouteController.steer(&aircraft[index], fixes: navigationFixesDomain)
            DirectRouteController.releaseOnArrival(&aircraft[index], fixes: navigationFixesDomain)
            // Localizer intercept: align with the centreline, then track it in.
            LocalizerGuidanceService.guide(&aircraft[index], runways: runways)
            physics.stepPhysics(&aircraft[index], dt: tickInterval)
            if aircraft[index].interceptRunway != nil,
               LocalizerGuidanceService.reachedRunway(aircraft[index], runways: runways) {
                landedIDs.insert(aircraft[index].id)
            }
            if tickCount % historySampleTicks == 0 {
                aircraft[index].history.append(aircraft[index].position)
                if aircraft[index].history.count > maxHistoryPoints {
                    aircraft[index].history.removeFirst()
                }
            }
        }

        // Reports the pilots owe: speak any that have just come due, now that
        // positions have advanced this tick.
        reports.advance(
            aircraft: aircraft,
            allCallsigns: Set((aircraft + traffic).map(\.callsign)),
            fixes: navigationFixesDomain,
            runways: runways)

        // Aircraft that reached the runway on the localizer have landed.
        if !landedIDs.isEmpty {
            if let sel = selectedAircraftID, landedIDs.contains(sel) { selectedAircraftID = nil }
            aircraft.removeAll { landedIDs.contains($0.id) }
        }

        // Holding capture: aircraft that reached their commanded hold fix leave
        // the radar and enter the holding hangar. The @Published side-effects
        // (clear selection, arm a refill for the freed slot) stay here.
        let captured = HoldingController.capture(aircraft: &aircraft, traffic: &traffic, fixes: holdingFixesDomain)
        if !captured.isEmpty {
            if let sel = selectedAircraftID, captured.contains(sel) { selectedAircraftID = nil }
            spawn.maintainCapacity(radarCount: aircraft.count)
        }

        // Fly the holding racetracks (runs every tick; only the drawing is gated
        // by the layer toggle).
        HoldingController.flyRacetracks(
            traffic: &traffic, fixes: holdingFixesDomain, physics: physics, dt: tickInterval,
            sampleHistory: tickCount % historySampleTicks == 0, maxHistory: maxHistoryPoints)

        // Aircraft-to-aircraft collisions.
        let acResult = collision.detectConflicts(in: aircraft)
        destroy(acResult.destroyed)
        let yellows = acResult.yellows.subtracting(acResult.destroyed)
        let reds    = acResult.reds.subtracting(acResult.destroyed)
        if yellows != yellowConflictIDs { yellowConflictIDs = yellows }
        if reds    != redConflictIDs    { redConflictIDs    = reds    }

        // Zone boundary collisions.
        let zoneResult = collision.detectZoneConflicts(aircraft: aircraft, zoneShapes: zoneShapes())
        destroy(zoneResult.destroyed)

        // After any destruction, arm a short-delay promotion so the slot refills quickly.
        if !acResult.destroyed.isEmpty || !zoneResult.destroyed.isEmpty {
            spawn.maintainCapacity(radarCount: aircraft.count)
        }
        let zoneWarnings = zoneResult.warnings.subtracting(zoneResult.destroyed)
        if zoneWarnings != zoneConflictIDs { zoneConflictIDs = zoneWarnings }

        // Fix collisions.
        let fixConflicts = collision.detectFixConflicts(aircraft: aircraft, fixes: fixes)
        if fixConflictIDs != fixConflicts { fixConflictIDs = fixConflicts }

        // Landing-sequence separation on final.
        let seqConflicts = SequencingSeparationService.conflicts(
            among: aircraft, runways: runways, aircraftTypes: aircraftTypes.map(\.asDomain))
        if sequencingConflictIDs != seqConflicts { sequencingConflictIDs = seqConflicts }

        // Advance the exercise clock; finish when we reach the target duration.
        elapsedSeconds += 1
        if exerciseDurationSeconds > 0, elapsedSeconds >= exerciseDurationSeconds {
            isExerciseFinished = true
            stopSimulation()
        }
    }

    /// How long the wreck stays on the radar before the aircraft leaves the scene.
    private static let wreckageDisplaySeconds = 1.5

    /// Marks aircraft destroyed, and removes them once the wreck has been shown.
    ///
    /// Both collision detectors end the same way and used to say so in two copies. Only
    /// IDs that were not already destroyed count, so an aircraft caught by both detectors
    /// on the same tick is scheduled for removal once rather than twice.
    private func destroy(_ ids: Set<UUID>) {
        let fresh = ids.subtracting(destroyedAircraftIDs)
        guard !fresh.isEmpty else { return }
        destroyedAircraftIDs.formUnion(fresh)
        if let sel = selectedAircraftID, fresh.contains(sel) { selectedAircraftID = nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wreckageDisplaySeconds) { [weak self] in
            guard let self else { return }
            self.aircraft.removeAll { fresh.contains($0.id) }
            self.traffic.removeAll  { fresh.contains($0.id) }
            self.destroyedAircraftIDs.subtract(fresh)
        }
    }

    // MARK: - Departure clearance

    /// Moves a departure aircraft from the hangar to its assigned runway threshold
    /// and starts the takeoff ground roll.
    /// Acts on takeoff clearances that have been issued but not yet carried out.
    ///
    /// `AircraftPhysics` records the clearance on the aircraft and stops there —
    /// putting one on a runway threshold moves it between the hangar and the radar,
    /// which is a change to the scene rather than to the aircraft's flight state.
    /// The same division `hold` and `interceptLocalizer` already use.
    private func rollClearedDepartures() {
        while let idx = traffic.firstIndex(where: { $0.pendingTakeoffRunway != nil }) {
            rollForTakeoff(at: idx)
        }
    }

    /// Moves a hangar departure onto its runway and starts the roll.
    private func rollForTakeoff(at idx: Int) {
        var ac = traffic[idx]
        let (threshold, heading) = RunwayGeometry.departureThreshold(for: ac, in: runways, center: center)

        ac.position           = threshold
        ac.headingDegrees     = heading
        ac.speedKnots         = 0
        ac.altitudeFeet       = 0
        ac.targetSpeedKnots   = Aircraft.defaultSpeedKnots
        ac.targetAltitudeFeet = 5000   // climb to FL050 after liftoff
        ac.takeoffState       = .groundRoll(runwayHeading: heading)
        ac.history            = []
        ac.pendingTakeoffRunway = nil

        traffic.remove(at: idx)
        aircraft.append(ac)
    }

    /// Resolves a live radar aircraft callsign from an already-normalised voice
    /// transcript. Holding aircraft (in the hangar) are included so they can be
    /// cleared/vectored by callsign.
    func resolveRadarCallsign(from normalizedText: String) -> String? {
        // Departures waiting in the hangar are included: a takeoff clearance names
        // an aircraft that is not on the radar yet.
        let candidates = aircraft
            + traffic.filter { $0.holdingName != nil || $0.category == .departure }
        return CallsignResolver.resolve(from: normalizedText, among: candidates, airlines: airlines.map(\.asDomain))
    }

    /// Applies commands to an aircraft found by callsign — no selection required.
    ///
    /// `readback` carries ICAO phraseology already rendered from the backend's own
    /// `readBackText`. When present it is spoken instead of the English that
    /// `CommandFeedbackManager` builds from the command enum — by that point the
    /// template is forgotten, so the real phraseology could never be used.
    func applyToCallsign(_ callsign: String,
                         commands: [AircraftCommand],
                         readback: String? = nil) {
        guard let id = (aircraft + traffic).first(where: {
            $0.callsign.uppercased() == callsign.uppercased()
        })?.id else {
            feedback.aircraftNotFound()
            return
        }
        applyCommands(commands, toAircraftWithID: id, readback: readback)
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
