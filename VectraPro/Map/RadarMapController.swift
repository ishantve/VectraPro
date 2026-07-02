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
    private var ringRadialLines: [MLNPolyline] = []
    private var ringRadialKey = ""
    private var stripLines: [UUID: [MLNPolyline]] = [:]
    private var localizerLineSets: [ApproachID: [MLNPolyline]] = [:]

    // Per-aircraft annotations, keyed by aircraft id (multi-aircraft support).
    private var aircraftAnnotations: [UUID: ImageAnnotation] = [:]
    private var labelAnnotations: [UUID: ImageAnnotation] = [:]
    private var labelTexts: [UUID: String] = [:]
    private var trailAnnotations: [UUID: [ImageAnnotation]] = [:]
    private var fixAnnotations: [ImageAnnotation] = []
    private var zoneAnnotations: [MLNAnnotation] = []
    private var zoneFillColors: [ObjectIdentifier: UIColor] = [:]
    private var tetherSource: MLNShapeSource?
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

    func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
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
        syncZones(mapView)
        syncFixes(mapView)
        syncAircraft(mapView)
    }

    /// Add each zone as a transparent fill polygon + solid border + center label.
    private func syncZones(_ mapView: MLNMapView) {
        guard zoneAnnotations.isEmpty else { return }
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

    /// Add an icon marker for each waypoint (triangle) and holding fix (built once).
    private func syncFixes(_ mapView: MLNMapView) {
        guard fixAnnotations.isEmpty else { return }
        addFixMarkers(viewModel.waypointFixes, icon: FixSymbol.triangle(), on: mapView)
        addFixMarkers(viewModel.holdingFixes, icon: FixSymbol.holding(), on: mapView)
    }

    private func addFixMarkers(_ fixes: [ExerciseDetail.Fix], icon: UIImage, on mapView: MLNMapView) {
        for fix in fixes {
            guard let lat = fix.latitude, let lon = fix.longitude else { continue }
            let annotation = ImageAnnotation()
            annotation.image = FixSymbol.marker(name: fix.fixName ?? "", icon: icon)
            annotation.coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            fixAnnotations.append(annotation)
            mapView.addAnnotation(annotation)
        }
    }

    private func applyZoomLimit(_ mapView: MLNMapView) {
        guard !didLimitZoom, mapView.bounds.width > 0, mapView.bounds.height > 0 else { return }
        let radius = 70 * 1852.0
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

        let radialKey = viewModel.radialManager.enabled.sorted().map(String.init).joined(separator: ",")
        if ringRadialLines.isEmpty || radialKey != ringRadialKey {
            remove(ringRadialLines, from: mapView)
            var lines = RangeRingRenderer.lines(viewModel.rings, around: viewModel.center)
            lines += RangeRingRenderer.lines(viewModel.areaControlRings, around: viewModel.center)
            lines += viewModel.fixRadialLines()
            ringRadialLines = add(lines, to: mapView)
            ringRadialKey = radialKey
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
            let offset = Geo.offset(from: aircraft.position,
                                    distanceMeters: aircraft.labelDistanceMeters,
                                    bearingDegrees: aircraft.labelBearingDegrees)
            if labelAnnotations[aircraft.id] == nil || labelTexts[aircraft.id] != text {
                let previous = labelAnnotations[aircraft.id]
                let a = ImageAnnotation()
                a.image = AircraftSymbol.label(text)
                if let img = a.image {
                    a.centerOffset = CGVector(dx: img.size.width / 2, dy: -img.size.height / 2)
                }
                a.coordinate = draggingLabelID == aircraft.id ? (previous?.coordinate ?? offset) : offset
                labelAnnotations[aircraft.id] = a
                mapView.addAnnotation(a)
                if let previous { mapView.removeAnnotation(previous) }
                labelTexts[aircraft.id] = text
            } else if draggingLabelID != aircraft.id {
                labelAnnotations[aircraft.id]?.coordinate = offset
            }

            syncTrail(aircraft.history, id: aircraft.id, on: mapView)
        }

        updateTethers(on: mapView)
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

    private func updateRotation(of annotation: ImageAnnotation, degrees: CGFloat, on mapView: MLNMapView) {
        annotation.rotationDegrees = degrees
        if let view = mapView.view(for: annotation) {
            view.transform = CGAffineTransform(rotationAngle: degrees * .pi / 180)
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

