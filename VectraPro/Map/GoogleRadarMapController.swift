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
//  • Aircraft + trail symbols are map-pinned: GMSGroundOverlays pinned to
//    symbolBaseZoom so they scale with the map (2^(zoom-base)), matching
//    RadarMapController.aircraftScale. (This replaced an earlier screen-fixed
//    GMSMarker approach, which jerked and appeared to resize during zoom because
//    the symbol stayed a fixed pixel size while the map scaled.)
//  • Dashed lines (trail, tether): GMS style-span dashes are geographic (metres),
//    while MapLibre dashes in screen points. We convert the MapLibre point cadence
//    to metres via the live metres-per-point (screenDashLengths) and recompute it
//    every sync, so the dashes hold a fixed on-screen cadence across zoom instead
//    of collapsing to a solid line at operational zoom.
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

    // Frame-aligned sync (mirrors RadarMapController): objectWillChange just sets
    // needsSync; a CADisplayLink drains it at most once per display frame. Aligning
    // to vsync keeps GMS's zoom animation smooth (a plain timer/throttle fires
    // mid-frame and makes zooming stutter).
    private var needsSync = false
    private var displayLink: CADisplayLink?
    private var displayLinkProxy: DisplayLinkProxy?

    // Environment tracking for external-display / window-size changes.
    private var lastKnownSize: CGSize = .zero
    private weak var lastScreen: UIScreen?

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
    /// Rebuild key for the range rings — the exercise centre (rings move if a replayed exercise recentres).
    private var ringLinesKey = ""
    /// VOR fix radials — rebuilt only when the Radials toggle or radials list changes.
    private var radialLines: [GMSPolyline] = []
    private var radialLinesKey = ""
    private var stripLines: [UUID: [GMSPolyline]] = [:]
    private var localizerLineSets: [ApproachID: [GMSPolyline]] = [:]

    /// Base zoom for map-pinned symbol scaling (symbol is native size here, scales
    /// 2^(zoom − base) elsewhere). RadarMapController/MapLibre uses base 8.8, but
    /// MapLibre GL measures zoom against 512-pt tiles while the Google Maps SDK
    /// uses 256-pt tiles, so for the SAME on-screen scale GMS reports a zoom one
    /// level HIGHER than MapLibre. We therefore use 8.8 + 1 = 9.8 so the symbol
    /// resolves to the same on-screen size as MapLibre/ArcGIS (without it, Google
    /// symbols come out 2× too big).
    private static let symbolBaseZoom: CGFloat = 9.8

    // Per-aircraft symbols, keyed by aircraft id (multi-aircraft support). Ground
    // overlays (not screen-fixed markers) so they scale smoothly with zoom.
    private var aircraftOverlays: [UUID: GMSGroundOverlay] = [:]
    /// Aircraft currently shown as a wreck (ground overlay sized for the wreck
    /// image); tracked so the overlay is rebuilt once on the destroyed transition.
    private var destroyedOverlayIDs: Set<UUID> = []
    private var labelMarkers: [UUID: GMSMarker] = [:]
    private var labelTexts: [UUID: String] = [:]
    /// Trail dots — map-pinned ground overlays (scale with zoom like the aircraft).
    private var trailMarkers: [UUID: [GMSGroundOverlay]] = [:]
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
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.needsSync = true }
            .store(in: &cancellables)

        // CADisplayLink drives sync frame-aligned. The link is retained by the run
        // loop, so it targets a weak proxy (not self) to avoid leaking the
        // controller when the radar view is recreated (e.g. provider switch).
        let proxy = DisplayLinkProxy()
        proxy.owner = self
        displayLinkProxy = proxy
        let dl = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.fire))
        dl.add(to: .main, forMode: .common)
        displayLink = dl
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

    /// Detects a change in the map view's size or host screen (e.g. moving to an
    /// external display) and, if so, clears the one-shot zoom-limit guard so the
    /// next applyZoomLimit re-fits the 65 NM bounds to the new viewport. Data-block
    /// labels re-bake at the new labelScale automatically on the same sync pass.
    /// GMS renders its GL surface at native scale, so — unlike MapLibre — there is
    /// no contentScaleFactor to manage. Returns true when a change was handled.
    @discardableResult
    private func handleEnvironmentChangeIfNeeded() -> Bool {
        let size = mapView.bounds.size
        let screen = mapView.window?.screen
        let sizeChanged = size != lastKnownSize && size.width > 0 && size.height > 0
        let screenChanged = screen !== lastScreen
        guard sizeChanged || screenChanged else { return false }
        lastKnownSize = size
        lastScreen = screen
        didLimitZoom = false
        return true
    }

    /// A resize / external-display move settles the camera without a model change,
    /// so re-fit here too (covers the case where the simulation is paused).
    func mapView(_ mapView: GMSMapView, idleAt position: GMSCameraPosition) {
        if handleEnvironmentChangeIfNeeded() { sync() }
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

    /// Called once per display frame by the CADisplayLink; runs sync() only if the
    /// model changed since the last frame (coalescing the tick's many emissions).
    fileprivate func displayLinkFired() {
        guard needsSync else { return }
        needsSync = false
        sync()
    }

    func sync() {
        // Disable GMS's implicit position/property animations for the whole pass.
        // GMSMarker animates every `position` change over ~0.2s by default; at high
        // simulation speeds (10X+) a new, far-away position arrives before the last
        // animation finishes, so markers visibly slide back and forth (jitter).
        // Applying updates instantly — as MapLibre does — removes the jitter.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        handleEnvironmentChangeIfNeeded()   // re-fit zoom limit on size/screen change
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

        // Range rings + area-control rings: rebuilt when the exercise centre changes (e.g. a replay whose
        // recorded exercise recentres the radar), not just once — otherwise they stay on the old centre.
        let ringsKey = "\(viewModel.center.latitude),\(viewModel.center.longitude)"
        if ringsKey != ringLinesKey {
            ringLines.forEach { $0.map = nil }
            var lines = RangeRingRenderer.lines(viewModel.rings, around: viewModel.center)
            lines += RangeRingRenderer.lines(viewModel.areaControlRings, around: viewModel.center)
            ringLines = add(lines)
            ringLinesKey = ringsKey
        }

        // Fix radials: rebuild when the Radials toggle, the enabled-radials list, OR the fixes change. The
        // fixes count matters because the radial lines are derived from `fixes` (fixRadialLines) — a replay
        // loads the exercise (and its fixes) after the radar is already up, so omitting it left radials blank.
        let radialsOn = viewModel.layerOn(.radials)
        let radialKey = "\(radialsOn)-\(viewModel.fixes.count)-" + viewModel.radialManager.enabled.sorted().map(String.init).joined(separator: ",")
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

        // Remove overlays for aircraft that no longer exist.
        for (id, overlay) in aircraftOverlays where !liveIDs.contains(id) {
            overlay.map = nil
            aircraftOverlays[id] = nil
            destroyedOverlayIDs.remove(id)
            labelMarkers[id]?.map = nil; labelMarkers[id] = nil
            labelTexts[id] = nil
            trailMarkers[id]?.forEach { $0.map = nil }; trailMarkers[id] = nil
            tethers[id]?.map = nil; tethers[id] = nil
            trailLines[id]?.map = nil; trailLines[id] = nil
        }

        for aircraft in current {
            let isDestroyed = viewModel.destroyedAircraftIDs.contains(aircraft.id)

            if isDestroyed {
                // Show the wreck and freeze label / trail / rotation until the
                // aircraft is removed — exactly as RadarMapController does. The
                // ground overlay is rebuilt once (on the transition) so its size
                // matches the wreck image rather than stretching the aircraft one.
                if !destroyedOverlayIDs.contains(aircraft.id) {
                    aircraftOverlays[aircraft.id]?.map = nil
                    aircraftOverlays[aircraft.id] = makeSymbolOverlay(
                        at: aircraft.position, icon: UIImage(named: "destroyed_Aircraft"))
                    destroyedOverlayIDs.insert(aircraft.id)
                }
                if let o = aircraftOverlays[aircraft.id] { moveSymbol(o, to: aircraft.position) }
                continue
            }

            // Symbol — map-pinned ground overlay (scales with zoom, see symbolBaseZoom).
            let overlay = aircraftOverlays[aircraft.id] ?? {
                let o = makeSymbolOverlay(at: aircraft.position, icon: AircraftSymbol.image())
                aircraftOverlays[aircraft.id] = o
                return o
            }()
            moveSymbol(overlay, to: aircraft.position)
            overlay.bearing = aircraft.headingDegrees

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

    /// Metres per screen point at symbolBaseZoom — measured once from the live GMS
    /// projection and cached. The symbol's geographic size is pointSize × this: a
    /// FIXED footprint that GMS scales natively as the map zooms. Measuring it from
    /// the live projection every frame made the symbol pulse/jerk during a zoom,
    /// because the mid-animation camera and projection briefly disagree.
    private var baseMetersPerPoint: Double = 0

    /// Measure + cache baseMetersPerPoint once the projection is laid out.
    private func ensureBaseMetersPerPoint() {
        guard baseMetersPerPoint == 0 else { return }
        let c = mapView.camera.target
        let p0 = mapView.projection.point(for: c)
        let p1 = mapView.projection.point(for: Geo.offset(from: c, distanceMeters: 1852, bearingDegrees: 90))
        let d = hypot(Double(p1.x - p0.x), Double(p1.y - p0.y))
        guard d > 0.5 else { return }   // projection not ready yet; retry next sync
        // metres-per-point scales as 1/2^zoom, so lift the current reading to the base zoom.
        baseMetersPerPoint = (1852.0 / d) * pow(2.0, Double(mapView.camera.zoom) - Double(Self.symbolBaseZoom))
    }

    /// Geographic bounds for a symbol of the given point size — a FIXED footprint
    /// (pointSize × the cached base metres-per-point) so it occupies pointSize ×
    /// 2^(zoom-base) screen points at any zoom, matching MapLibre, and scales
    /// smoothly with the map without any per-frame recomputation.
    private func symbolBounds(around center: CLLocationCoordinate2D, pointSize: CGSize) -> GMSCoordinateBounds {
        ensureBaseMetersPerPoint()
        let mpp = baseMetersPerPoint > 0 ? baseMetersPerPoint
            : 40_075_016.686 / (256.0 * pow(2.0, Double(Self.symbolBaseZoom))) * cos(center.latitude * .pi / 180)
        let halfW = Double(pointSize.width)  / 2 * mpp
        let halfH = Double(pointSize.height) / 2 * mpp
        let north = Geo.offset(from: center, distanceMeters: halfH, bearingDegrees: 0)
        let south = Geo.offset(from: center, distanceMeters: halfH, bearingDegrees: 180)
        let east  = Geo.offset(from: center, distanceMeters: halfW, bearingDegrees: 90)
        let west  = Geo.offset(from: center, distanceMeters: halfW, bearingDegrees: 270)
        return GMSCoordinateBounds(
            coordinate: CLLocationCoordinate2D(latitude: north.latitude, longitude: east.longitude),
            coordinate: CLLocationCoordinate2D(latitude: south.latitude, longitude: west.longitude))
    }

    /// Builds a map-pinned symbol: a ground overlay sized (via explicit bounds) to
    /// its icon's point size at symbolBaseZoom, scaling with the map at other zooms
    /// exactly like MapLibre's annotation view; rotatable via `bearing`.
    private func makeSymbolOverlay(at position: CLLocationCoordinate2D,
                                   icon: UIImage?, zIndex: Int32 = 1) -> GMSGroundOverlay {
        let o = GMSGroundOverlay(bounds: symbolBounds(around: position, pointSize: icon?.size ?? .zero),
                                 icon: icon)
        o.isTappable = false
        o.zIndex = zIndex   // aircraft (1) above trail dots (0); labels (markers) sit above both
        o.map = mapView
        return o
    }

    /// Re-centres an existing symbol overlay on `position`. Uses the cheap
    /// `position` setter (a translation that keeps the overlay's existing bounds
    /// size) rather than rebuilding `bounds` every sync — recomputing/​setting
    /// bounds re-tessellates the overlay in GMS, and doing that for every aircraft
    /// and trail dot each tick dropped frames and made zooming stutter.
    private func moveSymbol(_ overlay: GMSGroundOverlay, to position: CLLocationCoordinate2D) {
        overlay.position = position
    }

    private func syncTrail(_ history: [CLLocationCoordinate2D], id: UUID) {
        // Same sampling as RadarMapController: evenly-/fixed-spaced dots, not one
        // marker per raw history point.
        let positions = dynamicTrailSpacing
            ? TrailSampler.equalSpaced(from: history, count: 6)
            : TrailSampler.fixedSpaced(from: history, count: 6, spacingNM: fixedTrailSpacingNM)

        // Reuse existing markers instead of destroying and recreating all six every
        // sync — at high simulation speeds that churn (create/destroy + GL scene
        // mutation, per aircraft, per frame) was a real cost. Update positions/icons
        // in place and only add/remove the delta.
        var dots = trailMarkers[id] ?? []
        while dots.count > positions.count { dots.removeLast().map = nil }
        for index in positions.indices {
            if index < dots.count {
                // Fade (icon) for a given slot index is constant, so only move it.
                moveSymbol(dots[index], to: positions[index])
            } else {
                let fraction = positions.count > 1 ? Double(index) / Double(positions.count - 1) : 1.0
                let step = Int((fraction * Double(trailIcons.count - 1)).rounded())
                dots.append(makeSymbolOverlay(at: positions[index], icon: trailIcons[step], zIndex: 0))
            }
        }
        trailMarkers[id] = dots
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

    /// Metres covered by one screen point at `coord` under the current camera.
    /// GMS style-span dash lengths are geographic (metres), but MapLibre dashes in
    /// screen space; converting screen points → metres here (and recomputing every
    /// sync) makes the GMS dashes track a fixed on-screen cadence across zoom,
    /// matching MapLibre instead of collapsing to a solid line at operational zoom.
    private func metresPerPoint(at coord: CLLocationCoordinate2D) -> Double {
        let p = mapView.projection.point(for: coord)
        let onePointOver = mapView.projection.coordinate(for: CGPoint(x: p.x + 1, y: p.y))
        return GMSGeometryDistance(coord, onePointOver)
    }

    /// Screen-space dash lengths (in metres) for a GMS style span: `dashPoints`
    /// visible then `gapPoints` clear, sized from the live metres-per-point.
    private func screenDashLengths(dashPoints: Double, gapPoints: Double,
                                   at coord: CLLocationCoordinate2D) -> [NSNumber] {
        let mpp = metresPerPoint(at: coord)
        guard mpp > 0 else { return [NSNumber(value: dashPoints), NSNumber(value: gapPoints)] }
        return [NSNumber(value: dashPoints * mpp), NSNumber(value: gapPoints * mpp)]
    }

    /// Orange dashed spans matching RadarMapController's trail line (MapLibre dash
    /// pattern [4,5] in line-width units; stroke width 1.5 → 6 pt on / 7.5 pt off).
    private func trailDashSpans(for path: GMSPath) -> [GMSStyleSpan] {
        let orange = UIColor(red: 1.0, green: 0.65, blue: 0.2, alpha: 0.75)
        let anchor = path.count() > 0 ? path.coordinate(at: 0) : mapView.camera.target
        return GMSStyleSpans(path,
                             [GMSStrokeStyle.solidColor(orange), GMSStrokeStyle.solidColor(.clear)],
                             screenDashLengths(dashPoints: 6, gapPoints: 7.5, at: anchor),
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
    /// tether (MapLibre dash pattern [2,2] in line-width units; stroke width 1.5 →
    /// 3 pt on / 3 pt off), sized in screen space via the live metres-per-point.
    private func tetherDashSpans(for path: GMSPath) -> [GMSStyleSpan] {
        let white = UIColor.white.withAlphaComponent(0.5)
        let anchor = path.count() > 0 ? path.coordinate(at: 0) : mapView.camera.target
        return GMSStyleSpans(path,
                             [GMSStrokeStyle.solidColor(white), GMSStrokeStyle.solidColor(.clear)],
                             screenDashLengths(dashPoints: 3, gapPoints: 3, at: anchor),
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
    nonisolated deinit {
        displayLink?.invalidate()
    }
}

/// Weak-proxy target for the CADisplayLink. The run loop retains the link and the
/// link retains its target, so targeting this proxy (which only weakly references
/// the controller) prevents the link from keeping the controller alive forever.
private final class DisplayLinkProxy {
    weak var owner: GoogleRadarMapController?
    @objc func fire() { owner?.displayLinkFired() }
    nonisolated deinit { }
}
