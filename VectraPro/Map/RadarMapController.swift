//
//  RadarMapController.swift
//  VectraPro
//
//  Owns a single MLNMapView and all its rendering/gesture logic. Because the
//  map is owned here (not created per SwiftUI representable), the same map view
//  can be reparented between the iPad window and an external display without
//  reloading — giving a seamless transition.
//

import Combine
import GeoKit
import CoreLocation
import MapLibre
import UIKit

final class ImageAnnotation: MLNPointAnnotation {
    var image: UIImage?
    var rotationDegrees: CGFloat = 0
    /// Shift of the view centre from the coordinate (points). Default centred;
    /// the data block uses this to sit with its bottom-left corner on the point.
    var centerOffset: CGVector = .zero
    /// True for data-block labels (so they can be scaled down independently).
    var isLabel = false
}

final class RadarMapController: NSObject, MLNMapViewDelegate, UIGestureRecognizerDelegate {

    let mapView: MLNMapView
    private let viewModel: MapViewModel
    private var cancellables = Set<AnyCancellable>()

    private var styleLoaded = false
    private var didLimitZoom = false
    private var isClamping = false

    private var lastKnownSize: CGSize = .zero
    private weak var lastScreen: UIScreen?

    private enum PanMode { case none, map, label }
    private var panMode: PanMode = .none
    private var lastPanTranslation: CGPoint = .zero

    private var lineStyles: [ObjectIdentifier: (color: UIColor, width: CGFloat)] = [:]
    /// Range rings + area-control rings — built once, never removed.
    private var ringLines: [MLNPolyline] = []
    /// VOR fix radials — rebuilt only when the Radials toggle or radials list changes.
    private var radialLines: [MLNPolyline] = []
    private var radialLinesKey = ""
    private var stripLines: [UUID: [MLNPolyline]] = [:]
    private var localizerLineSets: [ApproachID: [MLNPolyline]] = [:]

    // Per-aircraft annotations, keyed by aircraft id (multi-aircraft support).
    private var aircraftAnnotations: [UUID: ImageAnnotation] = [:]
    private var labelAnnotations: [UUID: ImageAnnotation] = [:]
    private var labelTexts: [UUID: String] = [:]
    private var trailAnnotations: [UUID: [ImageAnnotation]] = [:]
    private var trailLineSource: MLNShapeSource?

    private let trailIcons: [UIImage] = (0..<8).map {
        AircraftSymbol.trailDot(fraction: Double($0) / 7)
    }
    /// true  = dot gap scales with aircraft speed (faster → wider gaps)
    /// false = fixed gap between every dot regardless of speed (default)
    private let dynamicTrailSpacing: Bool   = false
    /// Gap between trail dots when dynamicTrailSpacing is false (nautical miles).
    private let fixedTrailSpacingNM: Double = 0.60
    /// Fix icon markers — rebuilt only when the icon set (Fixes/Holding toggle, count) changes.
    private var fixIconAnnotations: [ImageAnnotation] = []
    /// Fix name labels — rebuilt only when the Fixes Names toggle changes (icons stay put).
    private var fixNameAnnotations: [ImageAnnotation] = []
    private var fixIconKey = ""
    private var fixNameKey = ""
    private var zoneAnnotations: [MLNAnnotation] = []
    private var zoneKey = ""
    private var zoneFillColors: [ObjectIdentifier: UIColor] = [:]
    private var tetherSource: MLNShapeSource?
    private var bodyDiamondSource: MLNShapeSource?
    private var noseDiamondSource: MLNShapeSource?
    private var normalCircleSource: MLNShapeSource?
    private var yellowCircleSource: MLNShapeSource?
    private var redCircleSource: MLNShapeSource?
    private var zoneColliderSource: MLNShapeSource?
    private var fixColliderSource: MLNShapeSource?
    private var selectionRingSource: MLNShapeSource?
    private var holdingRacetrackSource: MLNShapeSource?
    private var radialNameAnnotations: [ImageAnnotation] = []
    private var radialNameKey = ""
    /// Which aircraft's data block is being dragged (nil = none).
    private var draggingLabelID: UUID?

    // Sync throttling: objectWillChange just sets this flag; the CADisplayLink
    // drains it at most once per display frame (60 fps) — prevents 7+ sync() calls
    // per simulation tick from blocking the main thread.
    private var needsSync = false
    private var displayLink: CADisplayLink?

    // Distance measurement
    private var measurementLineSource: MLNShapeSource?
    private var measurementDotA: ImageAnnotation?
    private var measurementDotB: ImageAnnotation?
    private var measurementLabelAnnotation: ImageAnnotation?
    private var lastMeasurementText = ""

    init(viewModel: MapViewModel, styleURL: URL) {
        self.viewModel = viewModel
        self.mapView = MLNMapView(frame: .zero, styleURL: styleURL)
        super.init()
        setupMapView()

        // Drive updates from the model so the map refreshes regardless of which
        // window currently hosts it. Setting a flag here (not calling sync() directly)
        // lets the CADisplayLink drain it at most once per frame — collapses the 7+
        // objectWillChange emissions that tick() produces into a single sync() call.
        viewModel.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.needsSync = true }
            .store(in: &cancellables)

        let dl = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        dl.add(to: .main, forMode: .common)
        displayLink = dl

        viewModel.zoomPublisher
            .sink { [weak self] delta in self?.applyZoom(delta) }
            .store(in: &cancellables)

        viewModel.panPublisher
            .sink { [weak self] bearing in self?.panStep(towardBearing: bearing) }
            .store(in: &cancellables)
    }

    deinit {
        displayLink?.invalidate()
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        guard needsSync else { return }
        needsSync = false
        sync()
    }

    private func panStep(towardBearing bearing: Double) {
        let step = 3 * 1852.0   // 3 NM per key press
        let newCenter = Geo.offset(from: mapView.centerCoordinate, distanceMeters: step, bearingDegrees: bearing)
        mapView.setCenter(clampToRadius(newCenter), animated: true)
    }

    private func setupMapView() {
        mapView.delegate = self
        mapView.backgroundColor = .black   // black (not white) until tiles load
        mapView.logoView.isHidden = true
        mapView.attributionButton.isHidden = true
        mapView.showsUserLocation = false

        mapView.allowsZooming = true
        mapView.allowsScrolling = false
        mapView.allowsRotating = false
        mapView.allowsTilting = false
        mapView.setCenter(viewModel.center, zoomLevel: 8.5, animated: false)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        mapView.addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        mapView.addGestureRecognizer(tap)

        lastKnownSize = mapView.bounds.size
        lastScreen = mapView.window?.screen
    }

    private func applyZoom(_ delta: Double) {
        let target = max(mapView.minimumZoomLevel,
                         min(mapView.maximumZoomLevel, mapView.zoomLevel + delta))
        mapView.setZoomLevel(target, animated: true)
    }

    // MARK: Style load

    func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
        styleLoaded = true
        setupMeasurementLayer(style)
        setupTrailLayer(style)
        setupTetherLayer(style)
        setupBodyDiamondLayer(style)
        setupNoseDiamondLayer(style)
        setupNormalCircleLayer(style)
        setupYellowCircleLayer(style)
        setupRedCircleLayer(style)
        setupZoneColliderLayer(style)
        setupFixColliderLayer(style)
        setupSelectionRingLayer(style)
        setupHoldingRacetrackLayer(style)
        sync()
    }

    private func setupMeasurementLayer(_ style: MLNStyle) {
        let source = MLNShapeSource(identifier: "measurement-line", shape: nil, options: nil)
        style.addSource(source)
        let layer = MLNLineStyleLayer(identifier: "measurement-line", source: source)
        layer.lineColor = NSExpression(forConstantValue: UIColor.white)
        layer.lineWidth = NSExpression(forConstantValue: 1.5)
        layer.lineDashPattern = NSExpression(forConstantValue: [6, 4])
        style.addLayer(layer)
        measurementLineSource = source
    }

    private func setupTrailLayer(_ style: MLNStyle) {
        let source = MLNShapeSource(identifier: "aircraft-trails", shape: nil, options: nil)
        style.addSource(source)
        let layer = MLNLineStyleLayer(identifier: "aircraft-trails", source: source)
        layer.lineColor = NSExpression(forConstantValue: UIColor(red: 1.0, green: 0.65, blue: 0.2, alpha: 0.75))
        layer.lineWidth = NSExpression(forConstantValue: 1.5)
        layer.lineDashPattern = NSExpression(forConstantValue: [4, 5])
        style.addLayer(layer)
        trailLineSource = source
    }

    private func setupTetherLayer(_ style: MLNStyle) {
        let source = MLNShapeSource(identifier: "tether", shape: nil, options: nil)
        style.addSource(source)

        let layer = MLNLineStyleLayer(identifier: "tether", source: source)
        layer.lineColor = NSExpression(forConstantValue: UIColor.white.withAlphaComponent(0.5))
        layer.lineWidth = NSExpression(forConstantValue: 1.5)
        layer.lineDashPattern = NSExpression(forConstantValue: [2, 2])
        style.addLayer(layer)

        tetherSource = source
    }

    private func setupBodyDiamondLayer(_ style: MLNStyle) {
        let source = MLNShapeSource(identifier: "body-diamonds", shape: nil, options: nil)
        style.addSource(source)
        let layer = MLNLineStyleLayer(identifier: "body-diamonds", source: source)
        layer.lineColor = NSExpression(forConstantValue: UIColor.cyan)
        layer.lineWidth = NSExpression(forConstantValue: 1.5)
        layer.lineOpacity = NSExpression(forConstantValue: 0)
        style.addLayer(layer)
        bodyDiamondSource = source
    }

    private func setupNoseDiamondLayer(_ style: MLNStyle) {
        let source = MLNShapeSource(identifier: "nose-diamonds", shape: nil, options: nil)
        style.addSource(source)
        let layer = MLNLineStyleLayer(identifier: "nose-diamonds", source: source)
        layer.lineColor = NSExpression(forConstantValue: UIColor.magenta)
        layer.lineWidth = NSExpression(forConstantValue: 1.5)
        layer.lineOpacity = NSExpression(forConstantValue: 0)
        style.addLayer(layer)
        noseDiamondSource = source
    }

    private func setupNormalCircleLayer(_ style: MLNStyle) {
        let source = MLNShapeSource(identifier: "circles-normal", shape: nil, options: nil)
        style.addSource(source)
        let layer = MLNLineStyleLayer(identifier: "circles-normal", source: source)
        layer.lineColor = NSExpression(forConstantValue: UIColor.white.withAlphaComponent(0.35))
        layer.lineWidth = NSExpression(forConstantValue: 1.2)
        style.addLayer(layer)
        normalCircleSource = source
    }

    private func setupYellowCircleLayer(_ style: MLNStyle) {
        let source = MLNShapeSource(identifier: "circles-yellow", shape: nil, options: nil)
        style.addSource(source)
        let layer = MLNLineStyleLayer(identifier: "circles-yellow", source: source)
        layer.lineColor = NSExpression(forConstantValue: UIColor.systemYellow.withAlphaComponent(0.9))
        layer.lineWidth = NSExpression(forConstantValue: 1.8)
        layer.lineDashPattern = NSExpression(forConstantValue: [4, 3])
        style.addLayer(layer)
        yellowCircleSource = source
    }

    private func setupRedCircleLayer(_ style: MLNStyle) {
        let source = MLNShapeSource(identifier: "circles-red", shape: nil, options: nil)
        style.addSource(source)
        let layer = MLNLineStyleLayer(identifier: "circles-red", source: source)
        layer.lineColor = NSExpression(forConstantValue: UIColor.systemRed.withAlphaComponent(0.9))
        layer.lineWidth = NSExpression(forConstantValue: 1.8)
        layer.lineDashPattern = NSExpression(forConstantValue: [4, 3])
        style.addLayer(layer)
        redCircleSource = source
    }

    private func setupHoldingRacetrackLayer(_ style: MLNStyle) {
        let source = MLNShapeSource(identifier: "holding-racetracks", shape: nil, options: nil)
        style.addSource(source)
        let layer = MLNLineStyleLayer(identifier: "holding-racetracks", source: source)
        layer.lineColor = NSExpression(forConstantValue: UIColor.cyan.withAlphaComponent(0.85))
        layer.lineWidth = NSExpression(forConstantValue: 1.6)
        style.addLayer(layer)
        holdingRacetrackSource = source
    }

    private func setupZoneColliderLayer(_ style: MLNStyle) {
        let source = MLNShapeSource(identifier: "zone-colliders", shape: nil, options: nil)
        style.addSource(source)

        let layer = MLNLineStyleLayer(identifier: "zone-colliders", source: source)
        layer.lineColor = NSExpression(forConstantValue: UIColor.orange.withAlphaComponent(0.9))
        layer.lineWidth = NSExpression(forConstantValue: 1.8)
        layer.lineDashPattern = NSExpression(forConstantValue: [4, 3])
        style.addLayer(layer)

        zoneColliderSource = source
    }

    private func setupSelectionRingLayer(_ style: MLNStyle) {
        let source = MLNShapeSource(identifier: "selection-ring", shape: nil, options: nil)
        style.addSource(source)
        let layer = MLNLineStyleLayer(identifier: "selection-ring", source: source)
        layer.lineColor = NSExpression(forConstantValue: UIColor.systemGreen)
        layer.lineWidth = NSExpression(forConstantValue: 2.0)
        style.addLayer(layer)
        selectionRingSource = source
    }

    private func setupFixColliderLayer(_ style: MLNStyle) {
        let source = MLNShapeSource(identifier: "fix-colliders", shape: nil, options: nil)
        style.addSource(source)
        let layer = MLNLineStyleLayer(identifier: "fix-colliders", source: source)
        layer.lineColor = NSExpression(forConstantValue: UIColor.white.withAlphaComponent(0.45))
        layer.lineWidth = NSExpression(forConstantValue: 1.2)
        layer.lineDashPattern = NSExpression(forConstantValue: [3, 3])
        style.addLayer(layer)
        fixColliderSource = source
    }

    func mapViewDidFinishRenderingMapFullyRendered(_ mapView: MLNMapView) {
        handleViewEnvironmentChangeIfNeeded(mapView)
    }

    func mapViewDidBecomeIdle(_ mapView: MLNMapView) {
        handleViewEnvironmentChangeIfNeeded(mapView)
    }

    private func handleViewEnvironmentChangeIfNeeded(_ mapView: MLNMapView) {
        // Detect changes in size or the screen the view is presented on (e.g., external display moves)
        let currentSize = mapView.bounds.size
        let currentScreen = mapView.window?.screen
        let sizeChanged = currentSize != lastKnownSize && currentSize.width > 0 && currentSize.height > 0
        let screenChanged = currentScreen !== lastScreen
        guard sizeChanged || screenChanged else { return }
        lastKnownSize = currentSize
        lastScreen = currentScreen
        // Render at the host screen's native scale so the map (tiles + labels)
        // stays crisp on a high-resolution external display instead of blurry.
        if let screen = currentScreen {
            let scale = max(screen.nativeScale, screen.scale)
            if mapView.contentScaleFactor != scale {
                mapView.contentScaleFactor = scale
            }
        }
        // Re-apply the data-block scale for the new environment.
        let ls = labelScale
        for (_, label) in labelAnnotations {
            mapView.view(for: label)?.transform = CGAffineTransform(scaleX: ls, y: ls)
        }
        // Recompute zoom limits and visible bounds for the new environment
        didLimitZoom = false
        applyZoomLimit(mapView)
    }

    // MARK: Pan clamp (200 NM)

    func mapViewRegionIsChanging(_ mapView: MLNMapView) {
        refreshAircraftScale()
        syncFixColliders()
        syncSelectionRing()
    }

    func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
        refreshAircraftScale()
        syncFixColliders()
        if isClamping { isClamping = false; return }
        let clamped = clampToRadius(mapView.centerCoordinate)
        guard clamped.latitude != mapView.centerCoordinate.latitude
                || clamped.longitude != mapView.centerCoordinate.longitude else { return }
        isClamping = true
        mapView.setCenter(clamped, animated: false)
    }

    private func clampToRadius(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let radarCenter = viewModel.center
        let maxMeters = 200 * 1852.0
        let distance = Geo.distanceMeters(from: radarCenter, to: coordinate)
        guard distance > maxMeters else { return coordinate }
        let bearing = Geo.bearing(from: radarCenter, to: coordinate)
        return Geo.offset(from: radarCenter, distanceMeters: maxMeters, bearingDegrees: bearing)
    }

    // MARK: Sync

    func sync() {
        guard styleLoaded else { return }
        applyZoomLimit(mapView)
        syncStaticLines(mapView)
        syncRadialNames(mapView)
        syncZones(mapView)
        syncFixes(mapView)
        syncAircraft(mapView)
        syncColliders()
        syncFixColliders()
        syncSelectionRing()
        syncHoldingRacetracks()
        syncMeasurement()
    }

    /// Rotated name labels drawn along each VOR radial line.
    private func syncRadialNames(_ mapView: MLNMapView) {
        let showNames = viewModel.layerOn(.radialsNames) && viewModel.layerOn(.radials)
        let key = "\(showNames)-\(viewModel.fixes.count)"
        guard key != radialNameKey else { return }
        radialNameKey = key
        mapView.removeAnnotations(radialNameAnnotations)
        radialNameAnnotations = []
        guard showNames else { return }

        for label in viewModel.fixRadialLabels() {
            let img = FixSymbol.nameLabel(label.name)
            let annotation = ImageAnnotation()
            annotation.image = img
            annotation.coordinate = label.coordinate
            // Rotate text so it reads along the radial direction.
            // bearing - 90 converts map-bearing to screen rotation (East = 0°).
            // Clamp to [-90, 90] so text never appears upside-down.
            var rotation = label.bearing - 90
            if rotation > 90  { rotation -= 180 }
            if rotation < -90 { rotation += 180 }
            annotation.rotationDegrees = CGFloat(rotation)
            radialNameAnnotations.append(annotation)
            mapView.addAnnotation(annotation)
        }
    }

    /// Add each zone as a transparent fill polygon + solid border + center label.
    private func syncZones(_ mapView: MLNMapView) {
        let key = viewModel.layerOn(.zone) ? "on-\(viewModel.zones.count)" : "off"
        guard key != zoneKey else { return }
        zoneKey = key
        mapView.removeAnnotations(zoneAnnotations)
        zoneAnnotations = []
        guard viewModel.layerOn(.zone) else { return }
        for shape in viewModel.zoneShapes() {
            // Transparent fill.
            var fillCoords = shape.coordinates
            let polygon = MLNPolygon(coordinates: &fillCoords, count: UInt(fillCoords.count))
            zoneFillColors[ObjectIdentifier(polygon)] = shape.fillColor
            mapView.addAnnotation(polygon)
            zoneAnnotations.append(polygon)

            // Solid border (closed polyline).
            var borderCoords = shape.coordinates + [shape.coordinates[0]]
            let border = MLNPolyline(coordinates: &borderCoords, count: UInt(borderCoords.count))
            lineStyles[ObjectIdentifier(border)] = (shape.strokeColor, 1.2)
            mapView.addAnnotation(border)
            zoneAnnotations.append(border)

            // Center name label.
            let label = ImageAnnotation()
            label.image = ZoneRenderer.labelImage(shape.name)
            label.coordinate = shape.center
            mapView.addAnnotation(label)
            zoneAnnotations.append(label)
        }
    }

    /// Sync fix icon markers and name labels independently so toggling names
    /// never repositions the icon markers.
    private func syncFixes(_ mapView: MLNMapView) {
        let showFixes   = viewModel.layerOn(.fixes)
        let showHolding = viewModel.layerOn(.holding)
        let showNames   = viewModel.layerOn(.fixesNames)
        let iconKey = "\(showFixes)-\(showHolding)-\(viewModel.fixes.count)"
        let nameKey = "\(showNames)-\(iconKey)"

        if iconKey != fixIconKey {
            fixIconKey = iconKey
            mapView.removeAnnotations(fixIconAnnotations)
            fixIconAnnotations = []
            if showFixes   { addFixIcons(viewModel.waypointFixes, icon: FixSymbol.triangle(), on: mapView) }
            if showHolding { addFixIcons(viewModel.holdingFixes,   icon: FixSymbol.holding(),  on: mapView) }
        }

        if nameKey != fixNameKey {
            fixNameKey = nameKey
            mapView.removeAnnotations(fixNameAnnotations)
            fixNameAnnotations = []
            if showNames && showFixes   { addFixNames(viewModel.waypointFixes, iconSize: FixSymbol.triangle().size, on: mapView) }
            if showNames && showHolding { addFixNames(viewModel.holdingFixes,   iconSize: FixSymbol.holding().size,  on: mapView) }
        }
    }

    private func addFixIcons(_ fixes: [ExerciseDetail.Fix], icon: UIImage, on mapView: MLNMapView) {
        for fix in fixes {
            guard let lat = fix.latitude, let lon = fix.longitude else { continue }
            let annotation = ImageAnnotation()
            annotation.image = icon
            annotation.coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            fixIconAnnotations.append(annotation)
            mapView.addAnnotation(annotation)
        }
    }

    private func addFixNames(_ fixes: [ExerciseDetail.Fix], iconSize: CGSize, on mapView: MLNMapView) {
        let gap: CGFloat = 2
        for fix in fixes {
            guard let lat = fix.latitude, let lon = fix.longitude,
                  let name = fix.fixName, !name.isEmpty else { continue }
            let img = FixSymbol.nameLabel(name)
            let annotation = ImageAnnotation()
            annotation.image = img
            // Positive dy shifts the view's center DOWN from the coordinate,
            // placing the label below the icon without moving the icon itself.
            annotation.centerOffset = CGVector(dx: 0,
                                               dy: iconSize.height / 2 + gap + img.size.height / 2)
            annotation.coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            fixNameAnnotations.append(annotation)
            mapView.addAnnotation(annotation)
        }
    }

    private func applyZoomLimit(_ mapView: MLNMapView) {
        guard !didLimitZoom, mapView.bounds.width > 0, mapView.bounds.height > 0 else { return }
        let radius = 65 * 1852.0
        let center = viewModel.center
        let north = Geo.offset(from: center, distanceMeters: radius, bearingDegrees: 0)
        let south = Geo.offset(from: center, distanceMeters: radius, bearingDegrees: 180)
        let east = Geo.offset(from: center, distanceMeters: radius, bearingDegrees: 90)
        let west = Geo.offset(from: center, distanceMeters: radius, bearingDegrees: 270)
        let bounds = MLNCoordinateBounds(
            sw: CLLocationCoordinate2D(latitude: south.latitude, longitude: west.longitude),
            ne: CLLocationCoordinate2D(latitude: north.latitude, longitude: east.longitude)
        )
        mapView.setVisibleCoordinateBounds(bounds, animated: false)
        mapView.minimumZoomLevel = mapView.zoomLevel
        didLimitZoom = true
    }

    private func syncStaticLines(_ mapView: MLNMapView) {
        let enabled = viewModel.enabledApproaches
        let enabledStripIDs = Set(enabled.map(\.runwayID))

        // Range rings + area-control rings: built once, never removed or recreated.
        if ringLines.isEmpty {
            var lines = RangeRingRenderer.lines(viewModel.rings, around: viewModel.center)
            lines += RangeRingRenderer.lines(viewModel.areaControlRings, around: viewModel.center)
            ringLines = add(lines, to: mapView)
        }

        // Fix radials: only rebuild when Radials toggle or enabled-radials list changes.
        let radialsOn = viewModel.layerOn(.radials)
        let radialKey = "\(radialsOn)-" + viewModel.radialManager.enabled.sorted().map(String.init).joined(separator: ",")
        if radialKey != radialLinesKey {
            remove(radialLines, from: mapView)
            radialLines = radialsOn ? add(viewModel.fixRadialLines(), to: mapView) : []
            radialLinesKey = radialKey
        }

        for (id, lines) in stripLines where !enabledStripIDs.contains(id) {
            remove(lines, from: mapView)
            stripLines[id] = nil
        }
        for runway in viewModel.runways
        where enabledStripIDs.contains(runway.id) && stripLines[runway.id] == nil {
            var lines = RunwayRenderer.lines(runway)
            lines += LocalizerRenderer.stripGeometry(runway: runway)
            stripLines[runway.id] = add(lines, to: mapView)
        }

        for (id, lines) in localizerLineSets where !enabled.contains(id) {
            remove(lines, from: mapView)
            localizerLineSets[id] = nil
        }
        for approach in enabled where localizerLineSets[approach] == nil {
            guard let runway = viewModel.runway(for: approach.runwayID) else { continue }
            let lines = LocalizerRenderer.localizerLines(runway: runway, side: approach.side)
            localizerLineSets[approach] = add(lines, to: mapView)
        }
    }

    private func add(_ mapLines: [MapLine], to mapView: MLNMapView) -> [MLNPolyline] {
        var result: [MLNPolyline] = []
        for mapLine in mapLines {
            guard let polyline = polyline(from: mapLine) else { continue }
            result.append(polyline)
            mapView.addAnnotation(polyline)
        }
        return result
    }

    private func remove(_ lines: [MLNPolyline], from mapView: MLNMapView) {
        guard !lines.isEmpty else { return }
        mapView.removeAnnotations(lines)
        lines.forEach { lineStyles[ObjectIdentifier($0)] = nil }
    }

    private func polyline(from mapLine: MapLine) -> MLNPolyline? {
        guard mapLine.coordinates.count >= 2 else { return nil }
        var coords = mapLine.coordinates
        let polyline = MLNPolyline(coordinates: &coords, count: UInt(coords.count))
        lineStyles[ObjectIdentifier(polyline)] = (mapLine.color, mapLine.width)
        return polyline
    }

    // MARK: Aircraft

    private func syncAircraft(_ mapView: MLNMapView) {
        let current = viewModel.radarAircraft
        let liveIDs = Set(current.map(\.id))

        // Remove annotations for aircraft that no longer exist.
        for (id, symbol) in aircraftAnnotations where !liveIDs.contains(id) {
            mapView.removeAnnotation(symbol)
            aircraftAnnotations[id] = nil
            if let label = labelAnnotations[id] { mapView.removeAnnotation(label); labelAnnotations[id] = nil }
            labelTexts[id] = nil
            if let trail = trailAnnotations[id] { mapView.removeAnnotations(trail); trailAnnotations[id] = nil }
        }

        for aircraft in current {
            let isDestroyed = viewModel.destroyedAircraftIDs.contains(aircraft.id)

            // Symbol.
            let symbol = aircraftAnnotations[aircraft.id] ?? {
                let a = ImageAnnotation()
                a.image = AircraftSymbol.image()
                a.coordinate = aircraft.position
                aircraftAnnotations[aircraft.id] = a
                mapView.addAnnotation(a)
                return a
            }()
            if isDestroyed {
                symbol.image = UIImage(named: "destroyed_Aircraft")
                symbol.coordinate = aircraft.position
                // Skip label, trail and rotation updates for destroyed aircraft.
                continue
            }
            symbol.image = AircraftSymbol.image()
            symbol.coordinate = aircraft.position
            updateRotation(of: symbol, degrees: aircraft.headingDegrees, on: mapView)

            // Data block.
            let text = aircraft.dataBlock
            let isSelected = viewModel.selectedAircraftID == aircraft.id
            let isRed    = viewModel.redConflictIDs.contains(aircraft.id)
                        || viewModel.zoneConflictIDs.contains(aircraft.id)
            let isYellow = viewModel.yellowConflictIDs.contains(aircraft.id) && !isRed
            // Landing-sequence spacing warning (below the required separation).
            let isSeq    = viewModel.sequencingConflictIDs.contains(aircraft.id) && !isRed && !isYellow
            let blink    = viewModel.blinkState
            let conflictColor: UIColor? = blink
                ? (isRed ? .systemRed : isYellow ? .systemYellow : isSeq ? .systemOrange : nil)
                : nil
            let labelColor: UIColor?    = conflictColor ?? (isSelected ? .systemGreen : nil)
            let labelKey: String
            if isRed && blink         { labelKey = "\(text)-red" }
            else if isYellow && blink  { labelKey = "\(text)-yellow" }
            else if isSeq && blink     { labelKey = "\(text)-seq" }
            else if isSelected         { labelKey = "\(text)-selected" }
            else                       { labelKey = text }
            let offset = Geo.offset(from: aircraft.position,
                                    distanceMeters: aircraft.labelDistanceMeters,
                                    bearingDegrees: aircraft.labelBearingDegrees)
            if labelAnnotations[aircraft.id] == nil || labelTexts[aircraft.id] != labelKey {
                let previous = labelAnnotations[aircraft.id]
                let a = ImageAnnotation()
                a.isLabel = true
                a.image = AircraftSymbol.label(for: aircraft, conflictColor: labelColor)
                if let img = a.image {
                    a.centerOffset = CGVector(dx: img.size.width / 2, dy: -img.size.height / 2)
                }
                a.coordinate = draggingLabelID == aircraft.id ? (previous?.coordinate ?? offset) : offset
                labelAnnotations[aircraft.id] = a
                mapView.addAnnotation(a)
                if let previous { mapView.removeAnnotation(previous) }
                labelTexts[aircraft.id] = labelKey
            } else if draggingLabelID != aircraft.id {
                labelAnnotations[aircraft.id]?.coordinate = offset
            }

            syncTrailDots(aircraft.history, id: aircraft.id, on: mapView)
        }

        syncTrailLines()
        updateTethers(on: mapView)
        // Apply current zoom scale to any newly created annotations immediately
        // so they never appear at the wrong size for even one frame.
        refreshAircraftScale()
    }

    private func syncTrailDots(_ history: [CLLocationCoordinate2D], id: UUID, on mapView: MLNMapView) {
        if let old = trailAnnotations[id], !old.isEmpty {
            mapView.removeAnnotations(old)
        }

        let positions = dynamicTrailSpacing
            ? TrailSampler.equalSpaced(from: history, count: 6)
            : TrailSampler.fixedSpaced(from: history, count: 6, spacingNM: fixedTrailSpacingNM)
        guard !positions.isEmpty else { trailAnnotations[id] = []; return }

        let dots: [ImageAnnotation] = positions.indices.map { i in
            let fraction = positions.count > 1 ? Double(i) / Double(positions.count - 1) : 1.0
            let step     = Int((fraction * Double(trailIcons.count - 1)).rounded())
            let a        = ImageAnnotation()
            a.image      = trailIcons[step]
            a.coordinate = positions[i]
            return a
        }
        mapView.addAnnotations(dots)
        trailAnnotations[id] = dots
    }


    /// Rebuilds the trail dashed-line source from all aircraft history arrays.
    /// Each aircraft gets one polyline: history points (oldest→newest) + current position.
    private func syncTrailLines() {
        guard viewModel.layerOn(.trail) else {
            trailLineSource?.shape = nil
            return
        }
        var features: [MLNPolylineFeature] = []
        for ac in viewModel.radarAircraft {
            guard !ac.history.isEmpty else { continue }
            var coords = ac.history + [ac.position]
            features.append(MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count)))
        }
        trailLineSource?.shape = MLNShapeCollectionFeature(shapes: features)
    }

    /// One tether line per aircraft, from its symbol to the centre of the data
    /// block edge that faces the aircraft (left/right/top/bottom edge centre).
    private func updateTethers(on mapView: MLNMapView) {
        var features: [MLNPolylineFeature] = []
        for aircraft in viewModel.radarAircraft {
            guard let label = labelAnnotations[aircraft.id], let image = label.image else { continue }

            // Data-block centre + the aircraft, both in screen space.
            let anchor = mapView.convert(label.coordinate, toPointTo: mapView)
            let center = CGPoint(x: anchor.x + label.centerOffset.dx,
                                 y: anchor.y + label.centerOffset.dy)
            let acPoint = mapView.convert(aircraft.position, toPointTo: mapView)
            let halfW = image.size.width / 2, halfH = image.size.height / 2

            // Pick the edge centre on the side the aircraft is on.
            let dx = acPoint.x - center.x, dy = acPoint.y - center.y
            let edge: CGPoint
            if abs(dx) >= abs(dy) {
                edge = CGPoint(x: center.x + (dx < 0 ? -halfW : halfW), y: center.y)
            } else {
                edge = CGPoint(x: center.x, y: center.y + (dy < 0 ? -halfH : halfH))
            }

            let edgeCoord = mapView.convert(edge, toCoordinateFrom: mapView)
            var coords = [aircraft.position, edgeCoord]
            features.append(MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count)))
        }
        tetherSource?.shape = MLNShapeCollectionFeature(shapes: features)
    }

    /// Aircraft circles: always-visible white ring for every aircraft; yellow/red
    /// dashed ring replaces it during each blink-on phase when in conflict.
    /// Zone proximity ring (orange) is drawn separately.
    private func syncColliders() {
        // Body diamonds (cyan) and nose diamonds (magenta).
        var bodyDiamonds: [MLNPolylineFeature] = []
        var noseDiamonds: [MLNPolylineFeature] = []
        for ac in viewModel.aircraft {
            var bd = ColliderGeometry.diamond(center: ac.position,
                                   forwardNM: ac.bodyForwardNM, sideNM: ac.bodySideNM,
                                   headingDeg: ac.headingDegrees)
            bodyDiamonds.append(MLNPolylineFeature(coordinates: &bd, count: UInt(bd.count)))

            let noseCenter = Geo.offset(from: ac.position,
                                        distanceMeters: ac.noseOffsetNM * 1852,
                                        bearingDegrees: ac.headingDegrees)
            var nd = ColliderGeometry.noseRect(center: noseCenter,
                                    forwardNM: ac.noseForwardNM, sideNM: ac.noseSideNM,
                                    headingDeg: ac.headingDegrees)
            noseDiamonds.append(MLNPolylineFeature(coordinates: &nd, count: UInt(nd.count)))
        }
        bodyDiamondSource?.shape = MLNShapeCollectionFeature(shapes: bodyDiamonds)
        noseDiamondSource?.shape = MLNShapeCollectionFeature(shapes: noseDiamonds)

        var normalFeatures: [MLNPolylineFeature] = []
        var yellowFeatures: [MLNPolylineFeature] = []
        var redFeatures:    [MLNPolylineFeature] = []

        for ac in viewModel.aircraft {
            let isRed    = viewModel.redConflictIDs.contains(ac.id)
            let isYellow = viewModel.yellowConflictIDs.contains(ac.id) && !isRed
            let blink    = viewModel.blinkState
            var coords = ColliderGeometry.circle(center: ac.position, radiusNM: ac.colliderRadiusNM)
            coords.append(coords[0])
            let feature = MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
            if isRed && blink        { redFeatures.append(feature) }
            else if isYellow && blink { yellowFeatures.append(feature) }
            else                      { normalFeatures.append(feature) }
        }

        normalCircleSource?.shape = MLNShapeCollectionFeature(shapes: normalFeatures)
        yellowCircleSource?.shape = MLNShapeCollectionFeature(shapes: yellowFeatures)
        redCircleSource?.shape    = MLNShapeCollectionFeature(shapes: redFeatures)

        var zoneFeatures: [MLNPolylineFeature] = []
        for ac in viewModel.aircraft where viewModel.zoneConflictIDs.contains(ac.id) {
            var coords = ColliderGeometry.circle(center: ac.position, radiusNM: ac.colliderRadiusNM)
            coords.append(coords[0])
            zoneFeatures.append(MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count)))
        }
        zoneColliderSource?.shape = MLNShapeCollectionFeature(shapes: zoneFeatures)
    }

    // MARK: Holding racetracks

    /// Draws one oval racetrack per holding aircraft when the layer is on.
    private func syncHoldingRacetracks() {
        guard let source = holdingRacetrackSource else { return }
        guard viewModel.layerOn(.holdingRacetrack) else {
            source.shape = nil
            return
        }
        var features: [MLNPolylineFeature] = []
        for ac in viewModel.traffic where ac.holdingName != nil {
            guard let name = ac.holdingName,
                  let ic = ac.holdingInboundCourse,
                  let fix = viewModel.holdingFixPosition(named: name) else { continue }
            // Drawn racetrack resizes in real time with the current speed; the
            // aircraft only adopts the new size once it flies back onto inbound.
            let track = HoldingRacetrack(fix: fix, inboundCourse: ic, speedKnots: ac.speedKnots)
            var coords = track.outline()
            guard coords.count > 1 else { continue }
            features.append(MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count)))
        }
        source.shape = MLNShapeCollectionFeature(shapes: features)
    }

    /// Builds the 4 geographic vertices of a heading-aligned diamond + a closing point.
    ///
    /// The diamond has 4 cardinal vertices in the aircraft's local frame:
    ///   front  → bearing = headingDeg,       distance = forwardNM
    ///   right  → bearing = headingDeg + 90°, distance = sideNM
    ///   back   → bearing = headingDeg + 180°,distance = forwardNM
    ///   left   → bearing = headingDeg + 270°,distance = sideNM
    /// NM values are converted to metres (× 1852) for Geo.offset.
    /// The first point is repeated at the end to close the polyline on the map.
    /// Draws fix colliders: circle for HOLDING fixes, north-pointing triangle for all others.
    ///
    /// Fix icons are screen-space (fixed pixel size). Fix colliders are geographic (NM).
    /// As zoom increases, 1 NM = more pixels → the geographic collider would appear
    /// larger than the icon. To keep the collider visually aligned with the icon at all
    /// zoom levels, scale the NM value INVERSELY with zoom:
    ///   zoomScale = 2^(baseZoom − currentZoom)   [inverse of aircraftScale]
    /// At zoom 8.8 → zoomScale = 1.0  (no change)
    /// At zoom 9.8 → zoomScale = 0.5  (halve NM → same screen pixels as before)
    private func syncFixColliders() {
        // Fix / holding colliders are hidden from view — collision detection
        // (detectFixConflicts / hold capture) still runs independently.
        fixColliderSource?.shape = nil
    }

    private func updateRotation(of annotation: ImageAnnotation, degrees: CGFloat, on mapView: MLNMapView) {
        annotation.rotationDegrees = degrees
        if let view = mapView.view(for: annotation) {
            let s = aircraftScale(for: mapView)
            view.transform = CGAffineTransform(rotationAngle: degrees * .pi / 180).scaledBy(x: s, y: s)
        }
    }

    /// Scale factor to keep the aircraft symbol a constant geographic size as zoom changes.
    ///
    /// MapLibre zoom levels are powers of 2: each +1 level doubles the number of pixels
    /// per metre on screen. To make the symbol grow proportionally with zoom (so it always
    /// represents the same geographic footprint), multiply its screen size by 2^(ΔZoom):
    ///   scale = 2^(currentZoom − baseZoom)
    /// At zoom 8.8 (base) → scale = 2^0 = 1.0  (no scaling)
    /// At zoom 9.8        → scale = 2^1 = 2.0  (symbol appears twice as large on screen)
    /// At zoom 7.8        → scale = 2^−1 = 0.5 (symbol appears half as large)
    private func aircraftScale(for mapView: MLNMapView) -> CGFloat {
        CGFloat(pow(2.0, mapView.zoomLevel - 8.8))
    }

    /// Re-apply scale to aircraft symbols and trail dots when the user zooms interactively.
    private func refreshAircraftScale() {
        let s = aircraftScale(for: mapView)
        for (_, symbol) in aircraftAnnotations {
            if let view = mapView.view(for: symbol) {
                view.transform = CGAffineTransform(rotationAngle: symbol.rotationDegrees * .pi / 180)
                    .scaledBy(x: s, y: s)
            }
        }
        for (_, dots) in trailAnnotations {
            for dot in dots {
                if let view = mapView.view(for: dot) {
                    view.transform = CGAffineTransform(scaleX: s, y: s)
                }
            }
        }
    }

    // MARK: Annotation appearance

    func mapView(_ mapView: MLNMapView, strokeColorForShapeAnnotation annotation: MLNShape) -> UIColor {
        let id = ObjectIdentifier(annotation)
        // Zone fill polygons have no stroke — their border is a separate polyline.
        if zoneFillColors[id] != nil { return .clear }
        return lineStyles[id]?.color ?? .green
    }

    func mapView(_ mapView: MLNMapView, fillColorForPolygonAnnotation annotation: MLNPolygon) -> UIColor {
        zoneFillColors[ObjectIdentifier(annotation)] ?? .clear
    }

    func mapView(_ mapView: MLNMapView, lineWidthForPolylineAnnotation annotation: MLNPolyline) -> CGFloat {
        lineStyles[ObjectIdentifier(annotation)]?.width ?? 1
    }

    func mapView(_ mapView: MLNMapView, alphaForShapeAnnotation annotation: MLNShape) -> CGFloat { 1 }

    func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
        guard let imageAnnotation = annotation as? ImageAnnotation else { return nil }
        let view = MLNAnnotationView(reuseIdentifier: nil)
        guard let image = imageAnnotation.image else { return view }
        view.frame = CGRect(origin: .zero, size: image.size)
        view.centerOffset = imageAnnotation.centerOffset
        let imageView = UIImageView(image: image)
        imageView.frame = view.bounds
        view.addSubview(imageView)
        // Shrink data blocks a bit when full screen on an external display.
        if imageAnnotation.isLabel {
            view.transform = CGAffineTransform(scaleX: labelScale, y: labelScale)
        } else {
            view.transform = CGAffineTransform(rotationAngle: imageAnnotation.rotationDegrees * .pi / 180)
        }
        return view
    }

    /// Data-block scale — proportional to the radar view's size relative to the
    /// iPad's own screen (1.0 on the main window; smaller in a small detached
    /// window; larger on a big external display). Clamped to a sensible range.
    private var labelScale: CGFloat {
        let reference = UIScreen.main.bounds.height
        let h = mapView.bounds.height
        guard reference > 0, h > 0 else { return 1.0 }
        return min(1.4, max(0.6, h / reference))
    }

    /// Small green ring around the selected aircraft so it's visually distinct.
    private func syncSelectionRing() {
        guard let id = viewModel.selectedAircraftID,
              let ac = viewModel.radarAircraft.first(where: { $0.id == id }) else {
            selectionRingSource?.shape = nil
            return
        }
        var coords = ColliderGeometry.circle(center: ac.position, radiusNM: 0.4)
        coords.append(coords[0])
        let feature = MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
        selectionRingSource?.shape = MLNShapeCollectionFeature(shapes: [feature])
    }

    // MARK: - Distance measurement

    private func syncMeasurement() {
        guard viewModel.isDistanceMeasuring else {
            measurementLineSource?.shape = nil
            [measurementDotA, measurementDotB, measurementLabelAnnotation].forEach {
                if let a = $0 { mapView.removeAnnotation(a) }
            }
            measurementDotA = nil; measurementDotB = nil
            measurementLabelAnnotation = nil; lastMeasurementText = ""
            return
        }

        // --- dot A ---
        if let posA = viewModel.measurementPositionA {
            if measurementDotA == nil {
                let dot = ImageAnnotation()
                dot.image = measurementEndpointImage()
                dot.coordinate = posA
                mapView.addAnnotation(dot)
                measurementDotA = dot
            } else {
                measurementDotA?.coordinate = posA
            }
        } else {
            if let d = measurementDotA { mapView.removeAnnotation(d); measurementDotA = nil }
        }

        guard let posA = viewModel.measurementPositionA,
              let posB = viewModel.measurementPositionB else {
            // Only one point — clear line / label / dot B.
            measurementLineSource?.shape = nil
            if let d = measurementDotB { mapView.removeAnnotation(d); measurementDotB = nil }
            if let l = measurementLabelAnnotation { mapView.removeAnnotation(l); measurementLabelAnnotation = nil }
            lastMeasurementText = ""
            return
        }

        // --- dot B ---
        if measurementDotB == nil {
            let dot = ImageAnnotation()
            dot.image = measurementEndpointImage()
            dot.coordinate = posB
            mapView.addAnnotation(dot)
            measurementDotB = dot
        } else {
            measurementDotB?.coordinate = posB
        }

        // --- line ---
        var coords = [posA, posB]
        let feature = MLNPolylineFeature(coordinates: &coords, count: 2)
        measurementLineSource?.shape = MLNShapeCollectionFeature(shapes: [feature])

        // --- distance label at midpoint ---
        let distNM = Geo.distanceMeters(from: posA, to: posB) / 1852.0
        let text   = String(format: "%.1f NM", distNM)
        let mid    = CLLocationCoordinate2D(latitude:  (posA.latitude  + posB.latitude)  / 2,
                                            longitude: (posA.longitude + posB.longitude) / 2)
        if measurementLabelAnnotation == nil {
            let label = ImageAnnotation()
            label.image = measurementLabelImage(text)
            label.coordinate = mid
            mapView.addAnnotation(label)
            measurementLabelAnnotation = label
            lastMeasurementText = text
        } else {
            measurementLabelAnnotation?.coordinate = mid
            if text != lastMeasurementText {
                let prev = measurementLabelAnnotation!
                let label = ImageAnnotation()
                label.image = measurementLabelImage(text)
                label.coordinate = mid
                mapView.addAnnotation(label)
                mapView.removeAnnotation(prev)
                measurementLabelAnnotation = label
                lastMeasurementText = text
            }
        }
    }

    private func measurementEndpointImage() -> UIImage {
        let size: CGFloat = 10
        UIGraphicsBeginImageContextWithOptions(CGSize(width: size, height: size), false, 0)
        UIColor.white.setFill()
        UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: size - 2, height: size - 2)).fill()
        let img = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return img
    }

    private func measurementLabelImage(_ text: String) -> UIImage {
        let font  = UIFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let pad   = CGSize(width: 12, height: 6)
        let rect  = CGRect(origin: .zero,
                           size: CGSize(width: textSize.width + pad.width,
                                        height: textSize.height + pad.height))
        UIGraphicsBeginImageContextWithOptions(rect.size, false, 3)
        UIColor.black.withAlphaComponent(0.72).setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: 4).fill()
        UIColor.white.withAlphaComponent(0.35).setStroke()
        UIBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 4).stroke()
        (text as NSString).draw(in: rect.insetBy(dx: pad.width / 2, dy: pad.height / 2),
                                withAttributes: attrs)
        let img = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return img
    }

    // MARK: Pan (map + data block)

    /// Tap on a data block → select that aircraft. Tap elsewhere → deselect.
    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let point = gesture.location(in: mapView)

        // In measurement mode taps set anchors, not selection.
        if viewModel.isDistanceMeasuring {
            if let id = labelHit(point, in: mapView) {
                viewModel.addMeasurementAnchor(.aircraft(id))
            } else {
                let coord = mapView.convert(point, toCoordinateFrom: mapView)
                viewModel.addMeasurementAnchor(.fixed(coord))
            }
            return
        }

        if let id = labelHit(point, in: mapView) {
            let next: UUID? = viewModel.selectedAircraftID == id ? nil : id
            viewModel.selectAircraft(next)
        } else {
            viewModel.selectAircraft(nil)
        }
    }

    @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: mapView)

        switch gesture.state {
        case .began:
            if let id = labelHit(point, in: mapView) {
                panMode = .label
                draggingLabelID = id
            } else {
                panMode = .map
                lastPanTranslation = .zero
            }

        case .changed:
            switch panMode {
            case .label:
                guard let id = draggingLabelID, let label = labelAnnotations[id] else { return }
                label.coordinate = mapView.convert(point, toCoordinateFrom: mapView)
                updateTethers(on: mapView)

            case .map:
                let translation = gesture.translation(in: mapView)
                let delta = CGPoint(x: translation.x - lastPanTranslation.x,
                                    y: translation.y - lastPanTranslation.y)
                lastPanTranslation = translation
                let screenCenter = CGPoint(x: mapView.bounds.midX, y: mapView.bounds.midY)
                let target = CGPoint(x: screenCenter.x - delta.x, y: screenCenter.y - delta.y)
                let proposed = mapView.convert(target, toCoordinateFrom: mapView)
                mapView.setCenter(clampToRadius(proposed), animated: false)

            case .none:
                break
            }

        case .ended, .cancelled, .failed:
            if panMode == .label, let id = draggingLabelID,
               let aircraft = viewModel.radarAircraft.first(where: { $0.id == id }),
               let label = labelAnnotations[id] {
                let bearing = Geo.bearing(from: aircraft.position, to: label.coordinate)
                let distance = Geo.distanceMeters(from: aircraft.position, to: label.coordinate)
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

    /// The aircraft id whose data block contains `point` (nil = none).
    private func labelHit(_ point: CGPoint, in mapView: MLNMapView) -> UUID? {
        for (id, label) in labelAnnotations {
            guard let image = label.image else { continue }
            let anchor = mapView.convert(label.coordinate, toPointTo: mapView)
            // The view centre sits at anchor + centerOffset; rect is centred there.
            let center = CGPoint(x: anchor.x + label.centerOffset.dx,
                                 y: anchor.y + label.centerOffset.dy)
            let rect = CGRect(x: center.x - image.size.width / 2,
                              y: center.y - image.size.height / 2,
                              width: image.size.width, height: image.size.height)
            if rect.insetBy(dx: -16, dy: -16).contains(point) { return id }
        }
        return nil
    }
}

