//
//  GoogleRadarMapController.swift
//  VectraPro
//
//  Google Maps renderer for the radar. Mirrors RadarMapController (MapLibre)
//  but uses GMS APIs. Consumes the same provider-agnostic geometry (MapLine),
//  symbols (AircraftSymbol) and shared MapViewModel.
//
//  ── Feature parity with the MapLibre backend ────────────────────────────────
//  This backend is at feature parity with RadarMapController. Switching
//  MapProvider changes the rendering engine, not the feature set.
//
//  ── Intentional, accepted renderer differences (NOT parity defects) ─────────
//  • Aircraft/trail symbols are screen-fixed (constant on-screen size) rather
//    than scaling with zoom as MapLibre's do. GMSMarkers are screen-fixed by
//    design; emulating MapLibre's 2^(zoom-baseZoom) growth would need per-camera
//    icon regeneration (perf + jitter) or a GroundOverlay rewrite, for little
//    product value — screen-fixed radar symbols are acceptable/arguably better.
//  • Dashed lines (trail, distance measurement) use a geographic dash cadence.
//    GMS style-span dashes are geographic (rhumb/geodesic/projected), with no
//    screen-space option; MapLibre dashes in screen points. Exact screen-space
//    parity is only possible via a custom GMSProjection + Core Graphics overlay
//    (future optional work); the geographic approximation is accepted.
//  • Display DPI/crispness is handled natively by GMSMapView's GL surface — there
//    is no contentScaleFactor to manage as there is for MapLibre's MLNMapView.
//

import Combine
import ATCSimKit
import GeoNavKit
import CoreLocation
import GoogleMaps
import QuartzCore
import UIKit

final class GoogleRadarMapController: NSObject, GMSMapViewDelegate, UIGestureRecognizerDelegate {

    let mapView: GMSMapView
    private let viewModel: MapViewModel
    private var cancellables = Set<AnyCancellable>()

    private var didLimitZoom = false

    /// Opaque black view kept on top of the map until the first frame is fully
    /// rendered. GMSMapView paints its surface white for the first frames while
    /// the dark-styled tiles load, so without this the radar flashes white before
    /// turning black. Removed in mapViewSnapshotReady. (Does not affect load time —
    /// it only hides the white; both the cover and the styled map are black.)
    private var loadingCover: UIView?

    private enum PanMode { case none, map, label }
    private var panMode: PanMode = .none
    // Pan anchor captured once at gesture start — avoids re-projecting against a
    // stale GMSProjection every frame (which drifts / snaps back).
    private var panStartCenter = CLLocationCoordinate2D()
    private var latPerPoint: Double = 0
    private var lngPerPoint: Double = 0

    /// Range rings + area-control rings — built once, never removed.
    private var ringLines: [GMSPolyline] = []
    /// VOR fix radials — rebuilt only when the Radials toggle or radials list changes.
    private var radialLines: [GMSPolyline] = []
    private var radialLinesKey = ""
    private var stripLines: [UUID: [GMSPolyline]] = [:]
    private var localizerLineSets: [ApproachID: [GMSPolyline]] = [:]

    // Per-aircraft markers, keyed by aircraft id (multi-aircraft support).
    private var aircraftMarkers: [UUID: GMSMarker] = [:]
    private var labelMarkers: [UUID: GMSMarker] = [:]
    private var labelTexts: [UUID: String] = [:]
    private var trailMarkers: [UUID: [GMSMarker]] = [:]
    private var tethers: [UUID: GMSPolyline] = [:]
    private var fixIconMarkers: [GMSMarker] = []
    private var fixNameMarkers: [GMSMarker] = []
    private var fixIconKey = ""
    private var fixNameKey = ""
    private var radialNameMarkers: [GMSMarker] = []
    private var radialNameKey = ""
    /// Separation circles — always visible, one per aircraft. Color reflects conflict state.
    private var separationCircles: [UUID: GMSCircle] = [:]
    /// Orange rings — aircraft approaching a zone boundary.
    private var zoneColliderCircles: [UUID: GMSCircle] = [:]
    /// Green ring around the selected aircraft.
    private var selectionCircle: GMSCircle?
    /// Distance-measurement overlay: two endpoint dots, a dashed line, a label.
    private var measurementDotA: GMSMarker?
    private var measurementDotB: GMSMarker?
    private var measurementLine: GMSPolyline?
    private var measurementLabel: GMSMarker?
    private var lastMeasurementText = ""
    /// Holding-racetrack ovals, one per holding aircraft, shown only when the
    /// Holding-racetrack layer is on.
    private var holdingRacetrackLines: [UUID: GMSPolyline] = [:]
    private var zoneOverlays: [GMSOverlay] = []
    private var zoneKey = ""
    /// Which aircraft's data block is being dragged (nil = none).
    private var draggingLabelID: UUID?

    private let trailIcons: [UIImage] = (0..<8).map {
        AircraftSymbol.trailDot(fraction: Double($0) / 7)
    }
    /// Trail-dot spacing — mirrors RadarMapController: fixed 0.60 NM gaps (the
    /// dynamic-spacing branch is kept for parity with the same off-by-default flag).
    private let dynamicTrailSpacing = false
    private let fixedTrailSpacingNM = 0.60
    /// Dashed history line per aircraft, shown only when the Trail layer is on.
    private var trailLines: [UUID: GMSPolyline] = [:]

    init(viewModel: MapViewModel) {
        self.viewModel = viewModel
        let camera = GMSCameraPosition.camera(withTarget: viewModel.center, zoom: 8.5)
        // Start at a real (screen-sized) frame so the GL surface renders full
        // size immediately instead of flashing small then re-rendering.
        self.mapView = GMSMapView(frame: UIScreen.main.bounds, camera: camera)
        super.init()
        setupMapView()

        // Coalesce updates: MapViewModel.tick() emits objectWillChange 7+ times per
        // simulation tick. Calling sync() on each one runs the full per-object
        // render pass ~7× per tick and chokes the main thread (this is why Google
        // hangs where MapLibre — which coalesces via a CADisplayLink — does not).
        // Throttling to at most once per frame collapses each burst into a single
        // sync(), matching MapLibre's effective update rate.
        viewModel.objectWillChange
            .throttle(for: .milliseconds(16), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in self?.sync() }
            .store(in: &cancellables)
        viewModel.zoomPublisher
            .sink { [weak self] delta in self?.applyZoom(delta) }
            .store(in: &cancellables)
        viewModel.panPublisher
            .sink { [weak self] bearing in self?.panStep(towardBearing: bearing) }
            .store(in: &cancellables)
    }

    private func setupMapView() {
        mapView.delegate = self
        mapView.backgroundColor = .black   // dark base while tiles load (no white)
        mapView.mapStyle = try? GMSMapStyle(jsonString: Self.darkStyleJSON)
        mapView.settings.compassButton = false
        mapView.settings.myLocationButton = false
        mapView.isMyLocationEnabled = false
        mapView.settings.scrollGestures = false   // manual pan (clamped)
        mapView.settings.rotateGestures = false
        mapView.settings.tiltGestures = false

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        mapView.addGestureRecognizer(pan)

        // Black cover on top until the first frame renders — kills the white flash.
        // Interaction disabled so taps/pans still reach the map underneath.
        let cover = UIView(frame: mapView.bounds)
        cover.backgroundColor = .black
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.isUserInteractionEnabled = false
        mapView.addSubview(cover)
        loadingCover = cover
    }

    /// First fully-rendered frame (tiles loaded) — the map is now black, so it is
    /// safe to remove the cover with no white showing through.
    func mapViewSnapshotReady(_ mapView: GMSMapView) {
        loadingCover?.removeFromSuperview()
        loadingCover = nil
    }

    private func applyZoom(_ delta: Double) {
        let target = max(mapView.minZoom, min(mapView.maxZoom, mapView.camera.zoom + Float(delta)))
        mapView.animate(toZoom: target)
    }

    private func panStep(towardBearing bearing: Double) {
        let step = 3 * 1852.0
        let newCenter = Geo.offset(from: mapView.camera.target, distanceMeters: step, bearingDegrees: bearing)
        mapView.animate(toLocation: clampToRadius(newCenter))
    }

    // MARK: Sync

    func sync() {
        // Disable GMS's implicit position/property animations for the whole pass.
        // GMSMarker animates every `position` change over ~0.2s by default; at high
        // simulation speeds (10X+) a new, far-away position arrives before the last
        // animation finishes, so markers visibly slide back and forth (jitter).
        // Applying updates instantly — as MapLibre does — removes the jitter.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyZoomLimit()
        syncStaticLines()
        syncRadialNames()
        syncZones()
        syncFixes()
        syncAircraft()
        syncColliders()
        syncSelectionRing()
        syncHoldingRacetracks()
        syncMeasurement()
        CATransaction.commit()
    }

    /// Rotated name labels drawn along each VOR radial line.
    private func syncRadialNames() {
        let showNames = viewModel.layerOn(.radialsNames) && viewModel.layerOn(.radials)
        let key = "\(showNames)-\(viewModel.fixes.count)"
        guard key != radialNameKey else { return }
        radialNameKey = key
        radialNameMarkers.forEach { $0.map = nil }
        radialNameMarkers = []
        guard showNames else { return }

        for label in viewModel.fixRadialLabels() {
            let img = FixSymbol.nameLabel(label.name)
            var rotation = label.bearing - 90
            if rotation > 90  { rotation -= 180 }
            if rotation < -90 { rotation += 180 }
            let marker = GMSMarker(position: label.coordinate)
            marker.icon = img
            marker.rotation = rotation
            marker.groundAnchor = CGPoint(x: 0.5, y: 0.5)
            marker.isTappable = false
            marker.map = mapView
            radialNameMarkers.append(marker)
        }
    }

    /// Add each zone as a transparent fill polygon (solid border) + center label.
    private func syncZones() {
        let key = viewModel.layerOn(.zone) ? "on-\(viewModel.zones.count)" : "off"
        guard key != zoneKey else { return }
        zoneKey = key
        zoneOverlays.forEach { $0.map = nil }
        zoneOverlays = []
        guard viewModel.layerOn(.zone) else { return }
        for shape in viewModel.zoneShapes() {
            let path = GMSMutablePath()
            shape.coordinates.forEach { path.add($0) }
            let polygon = GMSPolygon(path: path)
            polygon.fillColor = shape.fillColor
            polygon.strokeColor = shape.strokeColor
            polygon.strokeWidth = 1.2
            polygon.map = mapView
            zoneOverlays.append(polygon)

            let label = GMSMarker(position: shape.center)
            label.icon = ZoneRenderer.labelImage(shape.name)
            label.groundAnchor = CGPoint(x: 0.5, y: 0.5)
            label.isTappable = false
            label.map = mapView
            zoneOverlays.append(label)
        }
    }

    /// Sync fix icon markers and name labels independently so toggling names
    /// never repositions the icon markers.
    private func syncFixes() {
        let showFixes   = viewModel.layerOn(.fixes)
        let showHolding = viewModel.layerOn(.holding)
        let showNames   = viewModel.layerOn(.fixesNames)
        let iconKey = "\(showFixes)-\(showHolding)-\(viewModel.fixes.count)"
        let nameKey = "\(showNames)-\(iconKey)"

        if iconKey != fixIconKey {
            fixIconKey = iconKey
            fixIconMarkers.forEach { $0.map = nil }
            fixIconMarkers = []
            if showFixes   { addFixIcons(viewModel.waypointFixes, icon: FixSymbol.triangle()) }
            if showHolding { addFixIcons(viewModel.holdingFixes,   icon: FixSymbol.holding()) }
        }

        if nameKey != fixNameKey {
            fixNameKey = nameKey
            fixNameMarkers.forEach { $0.map = nil }
            fixNameMarkers = []
            if showNames && showFixes   { addFixNames(viewModel.waypointFixes, iconSize: FixSymbol.triangle().size) }
            if showNames && showHolding { addFixNames(viewModel.holdingFixes,   iconSize: FixSymbol.holding().size) }
        }
    }

    private func addFixIcons(_ fixes: [ExerciseDetail.Fix], icon: UIImage) {
        for fix in fixes {
            guard let lat = fix.latitude, let lon = fix.longitude else { continue }
            let marker = GMSMarker(position: CLLocationCoordinate2D(latitude: lat, longitude: lon))
            marker.icon = icon
            marker.groundAnchor = CGPoint(x: 0.5, y: 0.5)
            marker.isTappable = false
            marker.map = mapView
            fixIconMarkers.append(marker)
        }
    }

    private func addFixNames(_ fixes: [ExerciseDetail.Fix], iconSize: CGSize) {
        let gap: CGFloat = 2
        for fix in fixes {
            guard let lat = fix.latitude, let lon = fix.longitude,
                  let name = fix.fixName, !name.isEmpty else { continue }
            let img = FixSymbol.nameLabel(name)
            // Build a transparent padded image whose top edge sits at the fix coord
            // (icon centre). The label occupies the bottom, separated from the icon
            // by gap — so the label appears below the icon without moving it.
            let canvasH = iconSize.height / 2 + gap + img.size.height
            let canvas = CGSize(width: img.size.width, height: canvasH)
            let paddedImg = UIGraphicsImageRenderer(size: canvas).image { _ in
                img.draw(at: CGPoint(x: 0, y: canvasH - img.size.height))
            }
            let marker = GMSMarker(position: CLLocationCoordinate2D(latitude: lat, longitude: lon))
            marker.icon = paddedImg
            marker.groundAnchor = CGPoint(x: 0.5, y: 0)   // top-centre at fix coord
            marker.isTappable = false
            marker.map = mapView
            fixNameMarkers.append(marker)
        }
    }

    private func applyZoomLimit() {
        guard !didLimitZoom, mapView.bounds.width > 0, mapView.bounds.height > 0 else { return }
        let radius = 65 * 1852.0
        let center = viewModel.center
        let north = Geo.offset(from: center, distanceMeters: radius, bearingDegrees: 0)
        let south = Geo.offset(from: center, distanceMeters: radius, bearingDegrees: 180)
        let east = Geo.offset(from: center, distanceMeters: radius, bearingDegrees: 90)
        let west = Geo.offset(from: center, distanceMeters: radius, bearingDegrees: 270)
        let bounds = GMSCoordinateBounds(
            coordinate: CLLocationCoordinate2D(latitude: north.latitude, longitude: east.longitude),
            coordinate: CLLocationCoordinate2D(latitude: south.latitude, longitude: west.longitude)
        )
        if let camera = mapView.camera(for: bounds, insets: .zero) {
            mapView.camera = camera
            mapView.setMinZoom(camera.zoom, maxZoom: mapView.maxZoom)
        }
        didLimitZoom = true
    }

    private func syncStaticLines() {
        let enabled = viewModel.enabledApproaches
        let enabledStripIDs = Set(enabled.map(\.runwayID))

        // Range rings + area-control rings: built once, never removed.
        if ringLines.isEmpty {
            var lines = RangeRingRenderer.lines(viewModel.rings, around: viewModel.center)
            lines += RangeRingRenderer.lines(viewModel.areaControlRings, around: viewModel.center)
            ringLines = add(lines)
        }

        // Fix radials: only rebuild when Radials toggle or enabled-radials list changes.
        let radialsOn = viewModel.layerOn(.radials)
        let radialKey = "\(radialsOn)-" + viewModel.radialManager.enabled.sorted().map(String.init).joined(separator: ",")
        if radialKey != radialLinesKey {
            radialLines.forEach { $0.map = nil }
            radialLines = radialsOn ? add(viewModel.fixRadialLines()) : []
            radialLinesKey = radialKey
        }

        for (id, lines) in stripLines where !enabledStripIDs.contains(id) {
            lines.forEach { $0.map = nil }
            stripLines[id] = nil
        }
        for runway in viewModel.runways
        where enabledStripIDs.contains(runway.id) && stripLines[runway.id] == nil {
            var lines = RunwayRenderer.lines(runway)
            lines += LocalizerRenderer.stripGeometry(runway: runway)
            stripLines[runway.id] = add(lines)
        }

        for (id, lines) in localizerLineSets where !enabled.contains(id) {
            lines.forEach { $0.map = nil }
            localizerLineSets[id] = nil
        }
        for approach in enabled where localizerLineSets[approach] == nil {
            guard let runway = viewModel.runway(for: approach.runwayID) else { continue }
            localizerLineSets[approach] = add(LocalizerRenderer.localizerLines(runway: runway, side: approach.side))
        }
    }

    private func add(_ mapLines: [MapLine]) -> [GMSPolyline] {
        mapLines.compactMap { mapLine in
            guard mapLine.coordinates.count >= 2 else { return nil }
            let path = GMSMutablePath()
            mapLine.coordinates.forEach { path.add($0) }
            let polyline = GMSPolyline(path: path)
            polyline.strokeColor = mapLine.color
            polyline.strokeWidth = mapLine.width
            polyline.map = mapView
            return polyline
        }
    }

    // MARK: Colliders

    /// One GMSCircle per aircraft, always visible. Stroke color reflects conflict level + blink state.
    /// Zone proximity circles (orange) are maintained separately.
    private func syncColliders() {
        let liveIDs = Set(viewModel.aircraft.map(\.id))
        let blink   = viewModel.blinkState

        // Body & nose collider diamonds are debug-only geometry — RadarMapController
        // computes them but keeps their layers invisible (lineOpacity 0). Collision
        // detection itself runs in MapViewModel, independent of any drawing, so we
        // simply don't draw them here (matching MapLibre's on-screen result).

        // — Separation circles (always visible, colour varies) —
        for id in Array(separationCircles.keys) where !liveIDs.contains(id) {
            separationCircles[id]?.map = nil; separationCircles[id] = nil
        }
        for ac in viewModel.aircraft {
            let r        = ac.colliderRadiusNM * 1852.0
            let isRed    = viewModel.redConflictIDs.contains(ac.id)
            let isYellow = viewModel.yellowConflictIDs.contains(ac.id) && !isRed
            let inConflict = (isRed || isYellow) && blink
            let stroke: UIColor = (isRed && blink)    ? UIColor.systemRed.withAlphaComponent(0.9)
                                : (isYellow && blink) ? UIColor.systemYellow.withAlphaComponent(0.9)
                                :                       UIColor.white.withAlphaComponent(0.35)
            // Match RadarMapController line widths (1.8 conflict, 1.2 normal) and,
            // like MapLibre, draw no fill — these are line-only rings. (A GMSCircle
            // cannot dash, so the conflict ring stays solid rather than dashed.)
            let width: CGFloat = inConflict ? 1.8 : 1.2
            if let c = separationCircles[ac.id] {
                c.position    = ac.position
                c.radius      = r
                c.strokeColor = stroke
                c.strokeWidth = width
            } else {
                let c = GMSCircle(position: ac.position, radius: r)
                c.strokeColor = stroke
                c.strokeWidth = width
                c.fillColor   = .clear
                c.map = mapView
                separationCircles[ac.id] = c
            }
        }

        // — Zone proximity (orange) —
        for id in Array(zoneColliderCircles.keys)
            where !viewModel.zoneConflictIDs.contains(id) || !liveIDs.contains(id) {
            zoneColliderCircles[id]?.map = nil; zoneColliderCircles[id] = nil
        }
        for ac in viewModel.aircraft where viewModel.zoneConflictIDs.contains(ac.id) {
            let r = ac.colliderRadiusNM * 1852.0
            if let c = zoneColliderCircles[ac.id] { c.position = ac.position; c.radius = r }
            else {
                let c = GMSCircle(position: ac.position, radius: r)
                c.strokeColor = UIColor.orange.withAlphaComponent(0.9)
                c.strokeWidth = 1.8
                c.fillColor   = .clear   // MapLibre draws this ring line-only, no fill
                c.map = mapView
                zoneColliderCircles[ac.id] = c
            }
        }
    }

    // MARK: Aircraft

    private func syncAircraft() {
        let current = viewModel.radarAircraft
        let liveIDs = Set(current.map(\.id))

        // Remove markers for aircraft that no longer exist.
        for (id, marker) in aircraftMarkers where !liveIDs.contains(id) {
            marker.map = nil
            aircraftMarkers[id] = nil
            labelMarkers[id]?.map = nil; labelMarkers[id] = nil
            labelTexts[id] = nil
            trailMarkers[id]?.forEach { $0.map = nil }; trailMarkers[id] = nil
            tethers[id]?.map = nil; tethers[id] = nil
            trailLines[id]?.map = nil; trailLines[id] = nil
        }

        for aircraft in current {
            let isDestroyed = viewModel.destroyedAircraftIDs.contains(aircraft.id)

            // Symbol.
            let marker = aircraftMarkers[aircraft.id] ?? {
                let m = GMSMarker(position: aircraft.position)
                m.icon = AircraftSymbol.image()
                m.groundAnchor = CGPoint(x: 0.5, y: 0.5)
                m.isFlat = true
                m.isTappable = false
                m.map = mapView
                aircraftMarkers[aircraft.id] = m
                return m
            }()
            if isDestroyed {
                // Show the wreck and freeze label / trail / rotation until the
                // aircraft is removed — exactly as RadarMapController does.
                marker.icon = UIImage(named: "destroyed_Aircraft")
                marker.position = aircraft.position
                continue
            }
            marker.icon = AircraftSymbol.image()
            marker.position = aircraft.position
            marker.rotation = aircraft.headingDegrees

            // Data block.
            let text = aircraft.dataBlock
            let isRed    = viewModel.redConflictIDs.contains(aircraft.id)
                        || viewModel.zoneConflictIDs.contains(aircraft.id)
            let isYellow = viewModel.yellowConflictIDs.contains(aircraft.id) && !isRed
            // Landing-sequence spacing warning (below the required separation).
            let isSeq    = viewModel.sequencingConflictIDs.contains(aircraft.id) && !isRed && !isYellow
            let isSelected = viewModel.selectedAircraftID == aircraft.id
            let blink    = viewModel.blinkState
            let conflictColor: UIColor? = blink
                ? (isRed ? .systemRed : isYellow ? .systemYellow : isSeq ? .systemOrange : nil)
                : nil
            let labelColor: UIColor? = conflictColor ?? (isSelected ? .systemGreen : nil)
            let labelKey: String
            if isRed && blink         { labelKey = "\(text)-red" }
            else if isYellow && blink  { labelKey = "\(text)-yellow" }
            else if isSeq && blink     { labelKey = "\(text)-seq" }
            else if isSelected         { labelKey = "\(text)-selected" }
            else                       { labelKey = text }
            let offset = Geo.offset(from: aircraft.position,
                                    distanceMeters: aircraft.labelDistanceMeters,
                                    bearingDegrees: aircraft.labelBearingDegrees)
            let label = labelMarkers[aircraft.id] ?? {
                let m = GMSMarker(position: offset)
                m.groundAnchor = CGPoint(x: 0, y: 1)   // bottom-left corner on the point
                m.isFlat = true
                // Not tappable: selection uses a geometric hit-test in didTapAt
                // (like RadarMapController), so the label must not swallow the tap.
                m.isTappable = false
                m.map = mapView
                labelMarkers[aircraft.id] = m
                return m
            }()
            // labelScale is part of the cache key so the block re-bakes at the new
            // size when the radar view is resized / moved to an external display.
            let scaledKey = "\(labelKey)@\(labelScale)"
            if labelTexts[aircraft.id] != scaledKey {
                label.icon = scaledLabel(AircraftSymbol.label(for: aircraft, conflictColor: labelColor),
                                         by: labelScale)
                labelTexts[aircraft.id] = scaledKey
            }
            if draggingLabelID != aircraft.id { label.position = offset }

            syncTrail(aircraft.history, id: aircraft.id)
            updateTether(for: aircraft.id, aircraftPosition: aircraft.position, label: label)
        }

        syncTrailLines()
    }

    private func syncTrail(_ history: [CLLocationCoordinate2D], id: UUID) {
        trailMarkers[id]?.forEach { $0.map = nil }
        // Same sampling as RadarMapController: evenly-/fixed-spaced dots, not one
        // marker per raw history point.
        let positions = dynamicTrailSpacing
            ? TrailSampler.equalSpaced(from: history, count: 6)
            : TrailSampler.fixedSpaced(from: history, count: 6, spacingNM: fixedTrailSpacingNM)
        guard !positions.isEmpty else { trailMarkers[id] = []; return }
        var markers: [GMSMarker] = []
        for index in positions.indices {
            let fraction = positions.count > 1 ? Double(index) / Double(positions.count - 1) : 1.0
            let step = Int((fraction * Double(trailIcons.count - 1)).rounded())
            let marker = GMSMarker(position: positions[index])
            marker.icon = trailIcons[step]
            marker.groundAnchor = CGPoint(x: 0.5, y: 0.5)
            marker.isTappable = false
            marker.map = mapView
            markers.append(marker)
        }
        trailMarkers[id] = markers
    }

    /// Dashed history line per aircraft (history + current position), shown only
    /// when the Trail layer is on. Mirrors RadarMapController.syncTrailLines.
    private func syncTrailLines() {
        guard viewModel.layerOn(.trail) else {
            trailLines.values.forEach { $0.map = nil }
            trailLines = [:]
            return
        }
        let liveIDs = Set(viewModel.radarAircraft.map(\.id))
        for (id, line) in trailLines where !liveIDs.contains(id) {
            line.map = nil; trailLines[id] = nil
        }
        for ac in viewModel.radarAircraft {
            guard !ac.history.isEmpty else {
                trailLines[ac.id]?.map = nil; trailLines[ac.id] = nil
                continue
            }
            let path = GMSMutablePath()
            ac.history.forEach { path.add($0) }
            path.add(ac.position)
            let line = trailLines[ac.id] ?? {
                let l = GMSPolyline(path: path)
                l.strokeWidth = 1.5
                l.map = mapView
                trailLines[ac.id] = l
                return l
            }()
            line.path = path
            line.spans = trailDashSpans(for: path)
        }
    }

    /// Orange dashed spans matching RadarMapController's trail-line colour.
    /// NOTE: MapLibre dashes in screen points ([4,5]); GMS style spans are
    /// geographic, so the dash *cadence* is an approximation (tunable) rather
    /// than pixel-identical — flagged for smoke-test.
    private func trailDashSpans(for path: GMSPath) -> [GMSStyleSpan] {
        let orange = UIColor(red: 1.0, green: 0.65, blue: 0.2, alpha: 0.75)
        return GMSStyleSpans(path,
                             [GMSStrokeStyle.solidColor(orange), GMSStrokeStyle.solidColor(.clear)],
                             [NSNumber(value: 200), NSNumber(value: 250)],
                             .rhumb)
    }

    /// Tether from the aircraft to the centre of the data-block edge that faces it
    /// (left/right/top/bottom edge centre), computed in screen space — mirrors
    /// RadarMapController.updateTethers, instead of anchoring at the block corner.
    private func updateTether(for id: UUID, aircraftPosition: CLLocationCoordinate2D, label: GMSMarker) {
        guard let image = label.icon else {
            tethers[id]?.map = nil; tethers[id] = nil
            return
        }
        // The label's bottom-left corner sits at label.position (groundAnchor 0,1),
        // so its view centre is half a width right and half a height up.
        let anchor = mapView.projection.point(for: label.position)
        let center = CGPoint(x: anchor.x + image.size.width / 2,
                             y: anchor.y - image.size.height / 2)
        let acPoint = mapView.projection.point(for: aircraftPosition)
        let halfW = image.size.width / 2, halfH = image.size.height / 2

        let dx = acPoint.x - center.x, dy = acPoint.y - center.y
        let edge: CGPoint
        if abs(dx) >= abs(dy) {
            edge = CGPoint(x: center.x + (dx < 0 ? -halfW : halfW), y: center.y)
        } else {
            edge = CGPoint(x: center.x, y: center.y + (dy < 0 ? -halfH : halfH))
        }

        let path = GMSMutablePath()
        path.add(aircraftPosition)
        path.add(mapView.projection.coordinate(for: edge))
        if let tether = tethers[id] {
            tether.path = path
            tether.spans = tetherDashSpans(for: path)
        } else {
            let line = GMSPolyline(path: path)
            line.strokeWidth = 1.5
            line.spans = tetherDashSpans(for: path)
            line.map = mapView
            tethers[id] = line
        }
    }

    /// White dashed spans for the tether. Mirrors RadarMapController's dashed
    /// tether (screen-space [2,2]); GMS style spans are geographic, so the cadence
    /// is the same accepted approximation used by the trail and measurement lines.
    private func tetherDashSpans(for path: GMSPath) -> [GMSStyleSpan] {
        let white = UIColor.white.withAlphaComponent(0.5)
        return GMSStyleSpans(path,
                             [GMSStrokeStyle.solidColor(white), GMSStrokeStyle.solidColor(.clear)],
                             [NSNumber(value: 150), NSNumber(value: 150)],
                             .rhumb)
    }

    // MARK: Holding racetracks

    /// One cyan oval per holding aircraft when the Holding-racetrack layer is on.
    /// Uses the shared HoldingRacetrack geometry; mirrors RadarMapController.
    private func syncHoldingRacetracks() {
        guard viewModel.layerOn(.holdingRacetrack) else {
            holdingRacetrackLines.values.forEach { $0.map = nil }
            holdingRacetrackLines = [:]
            return
        }
        let holdingIDs = Set(viewModel.traffic.filter { $0.holdingName != nil }.map(\.id))
        for (id, line) in holdingRacetrackLines where !holdingIDs.contains(id) {
            line.map = nil; holdingRacetrackLines[id] = nil
        }
        for ac in viewModel.traffic where ac.holdingName != nil {
            guard let name = ac.holdingName,
                  let ic = ac.holdingInboundCourse,
                  let fix = viewModel.holdingFixPosition(named: name) else {
                holdingRacetrackLines[ac.id]?.map = nil; holdingRacetrackLines[ac.id] = nil
                continue
            }
            // Resizes in real time with the current speed, like RadarMapController.
            let track = HoldingRacetrack(fix: fix, inboundCourse: ic, speedKnots: ac.speedKnots)
            let outline = track.outline()
            guard outline.count > 1 else { continue }
            let path = GMSMutablePath()
            outline.forEach { path.add($0) }
            if let line = holdingRacetrackLines[ac.id] {
                line.path = path
            } else {
                let line = GMSPolyline(path: path)
                line.strokeColor = UIColor.cyan.withAlphaComponent(0.85)
                line.strokeWidth = 1.6
                line.map = mapView
                holdingRacetrackLines[ac.id] = line
            }
        }
    }

    // MARK: Selection

    /// Small green ring around the selected aircraft, matching RadarMapController
    /// (0.4 NM radius). GMS has a native circle, so no polyline geometry is needed.
    private func syncSelectionRing() {
        guard let id = viewModel.selectedAircraftID,
              let ac = viewModel.radarAircraft.first(where: { $0.id == id }) else {
            selectionCircle?.map = nil
            selectionCircle = nil
            return
        }
        let radius = 0.4 * 1852.0
        if let c = selectionCircle {
            c.position = ac.position
            c.radius = radius
        } else {
            let c = GMSCircle(position: ac.position, radius: radius)
            c.strokeColor = .systemGreen
            c.strokeWidth = 2.0
            c.fillColor = .clear
            c.map = mapView
            selectionCircle = c
        }
    }

    /// Tap a data block → select that aircraft (tap again → deselect); tap
    /// elsewhere → deselect. Uses the same geometric hit-test as the label drag,
    /// mirroring RadarMapController.handleTap.
    func mapView(_ mapView: GMSMapView, didTapAt coordinate: CLLocationCoordinate2D) {
        let point = mapView.projection.point(for: coordinate)
        // In measurement mode, taps set anchors, not selection (mirrors RadarMapController).
        if viewModel.isDistanceMeasuring {
            if let id = labelHit(point) {
                viewModel.addMeasurementAnchor(.aircraft(id))
            } else {
                viewModel.addMeasurementAnchor(.fixed(coordinate))
            }
            return
        }
        if let id = labelHit(point) {
            viewModel.selectAircraft(viewModel.selectedAircraftID == id ? nil : id)
        } else {
            viewModel.selectAircraft(nil)
        }
    }

    // MARK: Distance measurement

    /// Two endpoint dots, a dashed connecting line, and a midpoint distance label,
    /// mirroring RadarMapController.syncMeasurement. Visual assets come from the
    /// shared MeasurementRenderer; placement is this controller's job.
    private func syncMeasurement() {
        guard viewModel.isDistanceMeasuring else {
            measurementLine?.map = nil;  measurementLine = nil
            measurementDotA?.map = nil;  measurementDotA = nil
            measurementDotB?.map = nil;  measurementDotB = nil
            measurementLabel?.map = nil; measurementLabel = nil
            lastMeasurementText = ""
            return
        }

        // Endpoint A.
        if let posA = viewModel.measurementPositionA {
            if let dot = measurementDotA { dot.position = posA }
            else {
                let dot = GMSMarker(position: posA)
                dot.icon = MeasurementRenderer.endpointImage()
                dot.groundAnchor = CGPoint(x: 0.5, y: 0.5)
                dot.isTappable = false
                dot.map = mapView
                measurementDotA = dot
            }
        } else {
            measurementDotA?.map = nil; measurementDotA = nil
        }

        // With only one point, clear the line / label / endpoint B.
        guard let posA = viewModel.measurementPositionA,
              let posB = viewModel.measurementPositionB else {
            measurementLine?.map = nil;  measurementLine = nil
            measurementDotB?.map = nil;  measurementDotB = nil
            measurementLabel?.map = nil; measurementLabel = nil
            lastMeasurementText = ""
            return
        }

        // Endpoint B.
        if let dot = measurementDotB { dot.position = posB }
        else {
            let dot = GMSMarker(position: posB)
            dot.icon = MeasurementRenderer.endpointImage()
            dot.groundAnchor = CGPoint(x: 0.5, y: 0.5)
            dot.isTappable = false
            dot.map = mapView
            measurementDotB = dot
        }

        // Connecting line.
        let path = GMSMutablePath()
        path.add(posA); path.add(posB)
        if let line = measurementLine {
            line.path = path; line.spans = measurementDashSpans(for: path)
        } else {
            let line = GMSPolyline(path: path)
            line.strokeWidth = 1.5
            line.spans = measurementDashSpans(for: path)
            line.map = mapView
            measurementLine = line
        }

        // Midpoint distance label.
        let distNM = Geo.distanceMeters(from: posA, to: posB) / 1852.0
        let text   = String(format: "%.1f NM", distNM)
        let mid    = CLLocationCoordinate2D(latitude:  (posA.latitude  + posB.latitude)  / 2,
                                            longitude: (posA.longitude + posB.longitude) / 2)
        if let label = measurementLabel {
            label.position = mid
            if text != lastMeasurementText {
                label.icon = MeasurementRenderer.labelImage(text)
                lastMeasurementText = text
            }
        } else {
            let label = GMSMarker(position: mid)
            label.icon = MeasurementRenderer.labelImage(text)
            label.groundAnchor = CGPoint(x: 0.5, y: 0.5)
            label.isTappable = false
            label.map = mapView
            measurementLabel = label
            lastMeasurementText = text
        }
    }

    /// White dashed spans for the measurement line. Same geographic-cadence caveat
    /// as the trail line — GMS style spans are geographic, not screen-space.
    private func measurementDashSpans(for path: GMSPath) -> [GMSStyleSpan] {
        GMSStyleSpans(path,
                      [GMSStrokeStyle.solidColor(.white), GMSStrokeStyle.solidColor(.clear)],
                      [NSNumber(value: 300), NSNumber(value: 200)],
                      .rhumb)
    }

    // MARK: Pan + clamp

    private func clampToRadius(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let maxMeters = 200 * 1852.0
        let distance = Geo.distanceMeters(from: viewModel.center, to: coordinate)
        guard distance > maxMeters else { return coordinate }
        let bearing = Geo.bearing(from: viewModel.center, to: coordinate)
        return Geo.offset(from: viewModel.center, distanceMeters: maxMeters, bearingDegrees: bearing)
    }

    @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: mapView)
        switch gesture.state {
        case .began:
            if let id = labelHit(point) {
                panMode = .label; draggingLabelID = id
            } else {
                panMode = .map
                // Capture the geographic-per-point scale ONCE here (zoom is fixed
                // during a pan) so we can apply the total translation against a
                // stable anchor instead of the live, lagging projection.
                let screenCenter = CGPoint(x: mapView.bounds.midX, y: mapView.bounds.midY)
                panStartCenter = mapView.camera.target
                let ref = mapView.projection.coordinate(for: screenCenter)
                let refRight = mapView.projection.coordinate(for: CGPoint(x: screenCenter.x + 100, y: screenCenter.y))
                let refDown = mapView.projection.coordinate(for: CGPoint(x: screenCenter.x, y: screenCenter.y + 100))
                lngPerPoint = (refRight.longitude - ref.longitude) / 100
                latPerPoint = (refDown.latitude - ref.latitude) / 100
            }
        case .changed:
            switch panMode {
            case .label:
                guard let id = draggingLabelID, let label = labelMarkers[id],
                      let aircraft = viewModel.aircraft.first(where: { $0.id == id }) else { return }
                // Disable the GMSMarker move animation so the block tracks the
                // finger with no lag.
                CATransaction.begin()
                CATransaction.setAnimationDuration(0)
                label.position = mapView.projection.coordinate(for: point)
                updateTether(for: id, aircraftPosition: aircraft.position, label: label)
                CATransaction.commit()
            case .map:
                let t = gesture.translation(in: mapView)
                // Dragging the finger right/down moves the camera target the
                // opposite way, anchored to where the pan began (no drift).
                let proposed = CLLocationCoordinate2D(
                    latitude: panStartCenter.latitude - Double(t.y) * latPerPoint,
                    longitude: panStartCenter.longitude - Double(t.x) * lngPerPoint
                )
                CATransaction.begin()
                CATransaction.setAnimationDuration(0)
                CATransaction.setDisableActions(true)
                mapView.camera = GMSCameraPosition(target: clampToRadius(proposed), zoom: mapView.camera.zoom)
                CATransaction.commit()
            case .none:
                break
            }
        case .ended, .cancelled, .failed:
            if panMode == .label, let id = draggingLabelID,
               let aircraft = viewModel.aircraft.first(where: { $0.id == id }),
               let label = labelMarkers[id] {
                let bearing = Geo.bearing(from: aircraft.position, to: label.position)
                let distance = Geo.distanceMeters(from: aircraft.position, to: label.position)
                viewModel.setLabelOffset(for: aircraft.id, bearingDegrees: bearing, distanceMeters: distance)
            }
            draggingLabelID = nil
            panMode = .none
        default:
            break
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { true }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    /// Data-block scale, proportional to the radar view's height relative to the
    /// iPad screen — smaller in a small detached window, larger on a big external
    /// display. Mirrors RadarMapController.labelScale (clamped 0.6…1.4).
    private var labelScale: CGFloat {
        let reference = UIScreen.main.bounds.height
        let h = mapView.bounds.height
        guard reference > 0, h > 0 else { return 1.0 }
        return min(1.4, max(0.6, h / reference))
    }

    /// GMSMarker has no view transform (unlike MapLibre's annotation view), so the
    /// data-block scale is baked into the label image instead.
    private func scaledLabel(_ image: UIImage, by scale: CGFloat) -> UIImage {
        guard scale != 1.0 else { return image }
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// The aircraft id whose data block contains `point` (nil = none).
    private func labelHit(_ point: CGPoint) -> UUID? {
        for (id, label) in labelMarkers {
            guard let image = label.icon else { continue }
            // Bottom-left corner anchored on the point (groundAnchor 0,1).
            let anchor = mapView.projection.point(for: label.position)
            let rect = CGRect(x: anchor.x,
                              y: anchor.y - image.size.height,
                              width: image.size.width, height: image.size.height)
            if rect.insetBy(dx: -16, dy: -16).contains(point) { return id }
        }
        return nil
    }

    private static let darkStyleJSON = """
    [
      { "elementType": "labels", "stylers": [{ "visibility": "off" }] },
      { "elementType": "geometry", "stylers": [{ "color": "#000000" }] },
      { "featureType": "road", "elementType": "geometry", "stylers": [{ "color": "#0a0a0a" }] },
      { "featureType": "road", "elementType": "geometry.stroke", "stylers": [{ "color": "#0a0a0a" }] },
      { "featureType": "road.highway", "elementType": "geometry", "stylers": [{ "color": "#0a0a0a" }] },
      { "featureType": "transit", "elementType": "geometry", "stylers": [{ "color": "#0a0a0a" }] },
      { "featureType": "water", "elementType": "geometry", "stylers": [{ "color": "#000000" }] }
    ]
    """

    /// Released classes need this. The target compiles with
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so a class's compiler-generated
    /// deinit is an isolated one, and the runtime hops an isolated deinit onto the
    /// main executor — which aborts the process on this toolchain (Swift 6.2.4).
    /// Singletons hide it by never being released; anything created per screen or
    /// per view is released for real. Declaring the deinit `nonisolated` says what is
    /// true — tearing this down needs no actor — and skips the hop.
    /// `IsolatedDeinitScanTests` is what catches a class that forgets it.
    nonisolated deinit { }
}
