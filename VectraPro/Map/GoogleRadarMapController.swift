//
//  GoogleRadarMapController.swift
//  VectraPro
//
//  Google Maps renderer for the radar. Mirrors RadarMapController (MapLibre)
//  but uses GMS APIs. Consumes the same provider-agnostic geometry (MapLine),
//  symbols (AircraftSymbol) and shared MapViewModel.
//

import Combine
import CoreLocation
import GoogleMaps
import QuartzCore
import UIKit

final class GoogleRadarMapController: NSObject, GMSMapViewDelegate, UIGestureRecognizerDelegate {

    let mapView: GMSMapView
    private let viewModel: MapViewModel
    private var cancellables = Set<AnyCancellable>()

    private var didLimitZoom = false

    private enum PanMode { case none, map, label }
    private var panMode: PanMode = .none
    // Pan anchor captured once at gesture start — avoids re-projecting against a
    // stale GMSProjection every frame (which drifts / snaps back).
    private var panStartCenter = CLLocationCoordinate2D()
    private var latPerPoint: Double = 0
    private var lngPerPoint: Double = 0

    private var ringRadialLines: [GMSPolyline] = []
    private var ringRadialKey = ""
    private var stripLines: [UUID: [GMSPolyline]] = [:]
    private var localizerLineSets: [ApproachID: [GMSPolyline]] = [:]

    // Per-aircraft markers, keyed by aircraft id (multi-aircraft support).
    private var aircraftMarkers: [UUID: GMSMarker] = [:]
    private var labelMarkers: [UUID: GMSMarker] = [:]
    private var labelTexts: [UUID: String] = [:]
    private var trailMarkers: [UUID: [GMSMarker]] = [:]
    private var tethers: [UUID: GMSPolyline] = [:]
    private var fixMarkers: [GMSMarker] = []
    private var zoneOverlays: [GMSOverlay] = []
    /// Which aircraft's data block is being dragged (nil = none).
    private var draggingLabelID: UUID?

    private let trailIcons: [UIImage] = (0..<8).map {
        AircraftSymbol.trailDot(fraction: Double($0) / 7)
    }

    init(viewModel: MapViewModel) {
        self.viewModel = viewModel
        let camera = GMSCameraPosition.camera(withTarget: viewModel.center, zoom: 8.5)
        // Start at a real (screen-sized) frame so the GL surface renders full
        // size immediately instead of flashing small then re-rendering.
        self.mapView = GMSMapView(frame: UIScreen.main.bounds, camera: camera)
        super.init()
        setupMapView()

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
        applyZoomLimit()
        syncStaticLines()
        syncZones()
        syncFixes()
        syncAircraft()
    }

    /// Add each zone as a transparent fill polygon (solid border) + center label.
    private func syncZones() {
        guard zoneOverlays.isEmpty else { return }
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

    /// Add an icon marker for each waypoint (triangle) and holding fix (built once).
    private func syncFixes() {
        guard fixMarkers.isEmpty else { return }
        addFixMarkers(viewModel.waypointFixes, icon: FixSymbol.triangle())
        addFixMarkers(viewModel.holdingFixes, icon: FixSymbol.holding())
    }

    private func addFixMarkers(_ fixes: [ExerciseDetail.Fix], icon: UIImage) {
        for fix in fixes {
            guard let lat = fix.latitude, let lon = fix.longitude else { continue }
            let marker = GMSMarker(position: CLLocationCoordinate2D(latitude: lat, longitude: lon))
            marker.icon = FixSymbol.marker(name: fix.fixName ?? "", icon: icon)
            marker.groundAnchor = CGPoint(x: 0.5, y: 0.5)
            marker.isTappable = false
            marker.map = mapView
            fixMarkers.append(marker)
        }
    }

    private func applyZoomLimit() {
        guard !didLimitZoom, mapView.bounds.width > 0, mapView.bounds.height > 0 else { return }
        let radius = 70 * 1852.0
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

        let radialKey = viewModel.radialManager.enabled.sorted().map(String.init).joined(separator: ",")
        if ringRadialLines.isEmpty || radialKey != ringRadialKey {
            ringRadialLines.forEach { $0.map = nil }
            var lines = RangeRingRenderer.lines(viewModel.rings, around: viewModel.center)
            lines += RangeRingRenderer.lines(viewModel.areaControlRings, around: viewModel.center)
            lines += viewModel.fixRadialLines()
            ringRadialLines = add(lines)
            ringRadialKey = radialKey
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

    // MARK: Aircraft

    private func syncAircraft() {
        let current = viewModel.aircraft
        let liveIDs = Set(current.map(\.id))

        // Remove markers for aircraft that no longer exist.
        for (id, marker) in aircraftMarkers where !liveIDs.contains(id) {
            marker.map = nil
            aircraftMarkers[id] = nil
            labelMarkers[id]?.map = nil; labelMarkers[id] = nil
            labelTexts[id] = nil
            trailMarkers[id]?.forEach { $0.map = nil }; trailMarkers[id] = nil
            tethers[id]?.map = nil; tethers[id] = nil
        }

        for aircraft in current {
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
            marker.position = aircraft.position
            marker.rotation = aircraft.headingDegrees

            // Data block.
            let text = aircraft.dataBlock
            let offset = Geo.offset(from: aircraft.position,
                                    distanceMeters: aircraft.labelDistanceMeters,
                                    bearingDegrees: aircraft.labelBearingDegrees)
            let label = labelMarkers[aircraft.id] ?? {
                let m = GMSMarker(position: offset)
                m.groundAnchor = CGPoint(x: 0, y: 1)   // bottom-left corner on the point
                m.isFlat = true
                m.map = mapView
                labelMarkers[aircraft.id] = m
                return m
            }()
            if labelTexts[aircraft.id] != text {
                label.icon = AircraftSymbol.label(text)
                labelTexts[aircraft.id] = text
            }
            if draggingLabelID != aircraft.id { label.position = offset }

            syncTrail(aircraft.history, id: aircraft.id)
            updateTether(for: aircraft.id, from: aircraft.position, to: label.position)
        }
    }

    private func syncTrail(_ history: [CLLocationCoordinate2D], id: UUID) {
        trailMarkers[id]?.forEach { $0.map = nil }
        var markers: [GMSMarker] = []
        for index in history.indices {
            let fraction = history.count > 1 ? Double(index) / Double(history.count - 1) : 1
            let step = Int((fraction * Double(trailIcons.count - 1)).rounded())
            let marker = GMSMarker(position: history[index])
            marker.icon = trailIcons[step]
            marker.groundAnchor = CGPoint(x: 0.5, y: 0.5)
            marker.isTappable = false
            marker.map = mapView
            markers.append(marker)
        }
        trailMarkers[id] = markers
    }

    private func updateTether(for id: UUID, from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) {
        let path = GMSMutablePath()
        path.add(start)
        path.add(end)
        if let tether = tethers[id] {
            tether.path = path
        } else {
            let line = GMSPolyline(path: path)
            line.strokeColor = UIColor.white.withAlphaComponent(0.5)
            line.strokeWidth = 1.5
            line.map = mapView
            tethers[id] = line
        }
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
                updateTether(for: id, from: aircraft.position, to: label.position)
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
}
