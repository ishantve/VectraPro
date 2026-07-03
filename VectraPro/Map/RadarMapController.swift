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
import CoreLocation
import MapLibre
import UIKit

final class ImageAnnotation: MLNPointAnnotation {
    var image: UIImage?
    var rotationDegrees: CGFloat = 0
    /// Shift of the view centre from the coordinate (points). Default centred;
    /// the data block uses this to sit with its bottom-left corner on the point.
    var centerOffset: CGVector = .zero
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
    private var radialNameAnnotations: [ImageAnnotation] = []
    private var radialNameKey = ""
    /// Which aircraft's data block is being dragged (nil = none).
    private var draggingLabelID: UUID?

    private let trailIcons: [UIImage] = (0..<8).map {
        AircraftSymbol.trailDot(fraction: Double($0) / 7)
    }

    init(viewModel: MapViewModel, styleURL: URL) {
        self.viewModel = viewModel
        self.mapView = MLNMapView(frame: .zero, styleURL: styleURL)
        super.init()
        setupMapView()

        // Drive updates from the model so the map refreshes regardless of which
        // window currently hosts it.
        viewModel.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.sync() }
            .store(in: &cancellables)

        viewModel.zoomPublisher
            .sink { [weak self] delta in self?.applyZoom(delta) }
            .store(in: &cancellables)

        viewModel.panPublisher
            .sink { [weak self] bearing in self?.panStep(towardBearing: bearing) }
            .store(in: &cancellables)
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
        setupTetherLayer(style)
        setupBodyDiamondLayer(style)
        setupNoseDiamondLayer(style)
        setupNormalCircleLayer(style)
        setupYellowCircleLayer(style)
        setupRedCircleLayer(style)
        setupZoneColliderLayer(style)
        sync()
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
        layer.lineColor = NSExpression(forConstantValue: UIColor.cyan.withAlphaComponent(0.9))
        layer.lineWidth = NSExpression(forConstantValue: 1.5)
        style.addLayer(layer)
        bodyDiamondSource = source
    }

    private func setupNoseDiamondLayer(_ style: MLNStyle) {
        let source = MLNShapeSource(identifier: "nose-diamonds", shape: nil, options: nil)
        style.addSource(source)
        let layer = MLNLineStyleLayer(identifier: "nose-diamonds", source: source)
        layer.lineColor = NSExpression(forConstantValue: UIColor.magenta.withAlphaComponent(0.9))
        layer.lineWidth = NSExpression(forConstantValue: 1.5)
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
        // Recompute zoom limits and visible bounds for the new environment
        didLimitZoom = false
        applyZoomLimit(mapView)
    }

    // MARK: Pan clamp (200 NM)

    func mapViewRegionIsChanging(_ mapView: MLNMapView) {
        refreshAircraftScale()
    }

    func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
        refreshAircraftScale()
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
    }

    /// Rotated name labels drawn along each VOR radial line.
    private func syncRadialNames(_ mapView: MLNMapView) {
        let showNames = viewModel.layerOn("Radials Names") && viewModel.layerOn("Radials")
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
        let key = viewModel.layerOn("Zone") ? "on-\(viewModel.zones.count)" : "off"
        guard key != zoneKey else { return }
        zoneKey = key
        mapView.removeAnnotations(zoneAnnotations)
        zoneAnnotations = []
        guard viewModel.layerOn("Zone") else { return }
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
        let showFixes   = viewModel.layerOn("Fixes")
        let showHolding = viewModel.layerOn("Holding")
        let showNames   = viewModel.layerOn("Fixes Names")
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
        let radialsOn = viewModel.layerOn("Radials")
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
        let current = viewModel.aircraft
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
            // Symbol.
            let symbol = aircraftAnnotations[aircraft.id] ?? {
                let a = ImageAnnotation()
                a.image = AircraftSymbol.image()
                a.coordinate = aircraft.position
                aircraftAnnotations[aircraft.id] = a
                mapView.addAnnotation(a)
                return a
            }()
            symbol.coordinate = aircraft.position
            updateRotation(of: symbol, degrees: aircraft.headingDegrees, on: mapView)

            // Data block.
            let text = aircraft.dataBlock
            let isRed    = viewModel.redConflictIDs.contains(aircraft.id)
                        || viewModel.zoneConflictIDs.contains(aircraft.id)
            let isYellow = viewModel.yellowConflictIDs.contains(aircraft.id) && !isRed
            let blink    = viewModel.blinkState
            let conflictColor: UIColor? = blink ? (isRed ? .systemRed : isYellow ? .systemYellow : nil) : nil
            let labelKey = conflictColor != nil ? "\(text)-\(isRed ? "red" : "yellow")" : text
            let offset = Geo.offset(from: aircraft.position,
                                    distanceMeters: aircraft.labelDistanceMeters,
                                    bearingDegrees: aircraft.labelBearingDegrees)
            if labelAnnotations[aircraft.id] == nil || labelTexts[aircraft.id] != labelKey {
                let previous = labelAnnotations[aircraft.id]
                let a = ImageAnnotation()
                a.image = AircraftSymbol.label(text, conflictColor: conflictColor)
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

            syncTrail(aircraft.history, id: aircraft.id, on: mapView)
        }

        updateTethers(on: mapView)
        // Apply current zoom scale to any newly created annotations immediately
        // so they never appear at the wrong size for even one frame.
        refreshAircraftScale()
    }

    private func syncTrail(_ history: [CLLocationCoordinate2D], id: UUID, on mapView: MLNMapView) {
        if let old = trailAnnotations[id] { mapView.removeAnnotations(old) }
        var annotations: [ImageAnnotation] = []
        for index in history.indices {
            let fraction = history.count > 1 ? Double(index) / Double(history.count - 1) : 1
            let step = Int((fraction * Double(trailIcons.count - 1)).rounded())
            let annotation = ImageAnnotation()
            annotation.image = trailIcons[step]
            annotation.coordinate = history[index]
            annotations.append(annotation)
            mapView.addAnnotation(annotation)
        }
        trailAnnotations[id] = annotations
    }

    /// One tether line per aircraft, from its symbol to its data block.
    private func updateTethers(on mapView: MLNMapView) {
        var features: [MLNPolylineFeature] = []
        for aircraft in viewModel.aircraft {
            guard let label = labelAnnotations[aircraft.id] else { continue }
            var coords = [aircraft.position, label.coordinate]
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
            var bd = diamondCoords(center: ac.position,
                                   forwardNM: ac.bodyForwardNM, sideNM: ac.bodySideNM,
                                   headingDeg: ac.headingDegrees)
            bodyDiamonds.append(MLNPolylineFeature(coordinates: &bd, count: UInt(bd.count)))

            let noseCenter = Geo.offset(from: ac.position,
                                        distanceMeters: ac.noseOffsetNM * 1852,
                                        bearingDegrees: ac.headingDegrees)
            var nd = noseRectCoords(center: noseCenter,
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
            var coords = circleCoords(center: ac.position, radiusNM: ac.colliderRadiusNM)
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
            var coords = circleCoords(center: ac.position, radiusNM: ac.colliderRadiusNM)
            coords.append(coords[0])
            zoneFeatures.append(MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count)))
        }
        zoneColliderSource?.shape = MLNShapeCollectionFeature(shapes: zoneFeatures)
    }

    /// 4 geographic vertices of a diamond (front, right, back, left) + closing point.
    private func diamondCoords(center: CLLocationCoordinate2D,
                                forwardNM: Double, sideNM: Double,
                                headingDeg: Double) -> [CLLocationCoordinate2D] {
        let offsets: [(Double, Double)] = [
            (forwardNM * 1852, headingDeg),
            (sideNM    * 1852, headingDeg + 90),
            (forwardNM * 1852, headingDeg + 180),
            (sideNM    * 1852, headingDeg + 270),
        ]
        var pts = offsets.map { Geo.offset(from: center, distanceMeters: $0.0, bearingDegrees: $0.1) }
        pts.append(pts[0])
        return pts
    }

    /// 4 geographic corners of a rectangle aligned to `headingDeg` + closing point.
    private func noseRectCoords(center: CLLocationCoordinate2D,
                                 forwardNM: Double, sideNM: Double,
                                 headingDeg: Double) -> [CLLocationCoordinate2D] {
        let front = Geo.offset(from: center, distanceMeters: forwardNM * 1852, bearingDegrees: headingDeg)
        let back  = Geo.offset(from: center, distanceMeters: forwardNM * 1852, bearingDegrees: headingDeg + 180)
        let fR = Geo.offset(from: front, distanceMeters: sideNM * 1852, bearingDegrees: headingDeg + 90)
        let fL = Geo.offset(from: front, distanceMeters: sideNM * 1852, bearingDegrees: headingDeg - 90)
        let bR = Geo.offset(from: back,  distanceMeters: sideNM * 1852, bearingDegrees: headingDeg + 90)
        let bL = Geo.offset(from: back,  distanceMeters: sideNM * 1852, bearingDegrees: headingDeg - 90)
        return [fL, fR, bR, bL, fL]
    }

    private func circleCoords(center: CLLocationCoordinate2D, radiusNM: Double, steps: Int = 36) -> [CLLocationCoordinate2D] {
        (0..<steps).map { i in
            Geo.offset(from: center,
                       distanceMeters: radiusNM * 1852.0,
                       bearingDegrees: Double(i) * 360.0 / Double(steps))
        }
    }

    private func updateRotation(of annotation: ImageAnnotation, degrees: CGFloat, on mapView: MLNMapView) {
        annotation.rotationDegrees = degrees
        if let view = mapView.view(for: annotation) {
            let s = aircraftScale(for: mapView)
            view.transform = CGAffineTransform(rotationAngle: degrees * .pi / 180).scaledBy(x: s, y: s)
        }
    }

    /// Scale factor so aircraft symbol grows proportionally with zoom.
    /// At the base zoom (8.8) scale = 1; doubles for each zoom level above it.
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
        view.transform = CGAffineTransform(rotationAngle: imageAnnotation.rotationDegrees * .pi / 180)
        return view
    }

    // MARK: Pan (map + data block)

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
               let aircraft = viewModel.aircraft.first(where: { $0.id == id }),
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

