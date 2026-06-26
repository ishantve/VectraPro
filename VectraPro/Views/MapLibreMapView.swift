//
//  MapLibreMapView.swift
//  VectraPro
//
//  MapLibre + OpenStreetMap radar map. Static geometry (range rings, runways,
//  localizers, cones, circuits) is drawn as styled polyline annotations; the
//  aircraft, its leader line, history trail and draggable data block are
//  managed as annotation views / polylines and updated each tick.
//

import Combine
import CoreLocation
import MapLibre
import SwiftUI

struct MapLibreMapView: UIViewRepresentable {

    @ObservedObject var viewModel: MapViewModel

    func makeCoordinator() -> Coordinator { Coordinator(viewModel: viewModel) }

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(frame: .zero, styleURL: MapStyleProvider.darkOSMStyleURL())
        mapView.delegate = context.coordinator
        context.coordinator.mapView = mapView

        // Hide MapLibre chrome: logo, attribution "ⓘ" info button, user-location pin.
        mapView.logoView.isHidden = true
        mapView.attributionButton.isHidden = true
        mapView.showsUserLocation = false

        // Gestures: pinch zoom only; panning is handled manually (below) so we
        // can hard-clamp it to a 200 NM radius.
        mapView.allowsZooming = true
        mapView.allowsScrolling = false
        mapView.allowsRotating = false
        mapView.allowsTilting = false
        mapView.setCenter(viewModel.center, zoomLevel: 8.5, animated: false)

        // Zoom buttons (SwiftUI) drive zoom through the view model.
        context.coordinator.zoomCancellable = viewModel.zoomPublisher.sink { [weak mapView] delta in
            guard let mapView else { return }
            let target = max(mapView.minimumZoomLevel,
                             min(mapView.maximumZoomLevel, mapView.zoomLevel + delta))
            mapView.setZoomLevel(target, animated: true)
        }

        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        pan.delegate = context.coordinator
        pan.maximumNumberOfTouches = 1   // leave 2-finger pinch to the map
        mapView.addGestureRecognizer(pan)

        return mapView
    }

    func updateUIView(_ uiView: MLNMapView, context: Context) {
        context.coordinator.sync()
    }

    // MARK: - Annotations

    final class ImageAnnotation: MLNPointAnnotation {
        var image: UIImage?
        var rotationDegrees: CGFloat = 0
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MLNMapViewDelegate, UIGestureRecognizerDelegate {

        weak var mapView: MLNMapView?
        var zoomCancellable: AnyCancellable?
        private let viewModel: MapViewModel

        private var styleLoaded = false
        private var didLimitZoom = false
        private var isClamping = false

        private enum PanMode { case none, map, label }
        private var panMode: PanMode = .none
        private var lastPanTranslation: CGPoint = .zero

        // Static line styling lookup.
        private var lineStyles: [ObjectIdentifier: (color: UIColor, width: CGFloat)] = [:]
        // Tracked per owner so a single toggle only touches its own overlays
        // (no full radar rebuild / blink).
        private var ringRadialLines: [MLNPolyline] = []
        private var ringRadialKey = ""
        private var stripLines: [UUID: [MLNPolyline]] = [:]
        private var localizerLineSets: [ApproachID: [MLNPolyline]] = [:]

        // Aircraft overlays.
        private var aircraftAnnotation: ImageAnnotation?
        private var labelAnnotation: ImageAnnotation?
        private var lastLabelText = ""
        private var trailAnnotations: [ImageAnnotation] = []
        private var tetherSource: MLNShapeSource?
        private var isDraggingLabel = false

        private let trailIcons: [UIImage] = (0..<8).map {
            AircraftSymbol.trailDot(fraction: Double($0) / 7)
        }

        init(viewModel: MapViewModel) {
            self.viewModel = viewModel
        }

        // MARK: Style load

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            styleLoaded = true
            setupTetherLayer(style)
            sync()
        }

        /// A runtime source + line layer for the data-block tether, updated in
        /// place (no annotation churn) so dragging never blinks.
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

        // Safety clamp after any settle (zoom momentum, programmatic moves).
        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            if isClamping { isClamping = false; return }
            let clamped = clampToRadius(mapView.centerCoordinate)
            guard clamped.latitude != mapView.centerCoordinate.latitude
                    || clamped.longitude != mapView.centerCoordinate.longitude else { return }
            isClamping = true
            mapView.setCenter(clamped, animated: false)
        }

        /// Clamp a coordinate to within the 200 NM radius of the radar center.
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
            guard styleLoaded, let mapView else { return }
            applyZoomLimit(mapView)
            syncStaticLines(mapView)
            syncAircraft(mapView)
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

        // MARK: Static lines

        private func syncStaticLines(_ mapView: MLNMapView) {
            let enabled = viewModel.enabledApproaches
            let enabledStripIDs = Set(enabled.map(\.runwayID))

            // Rings + radials — independent of approach toggles. Rebuilt only
            // when the radial set changes.
            let radialKey = viewModel.radialManager.enabled.sorted().map(String.init).joined(separator: ",")
            if ringRadialLines.isEmpty || radialKey != ringRadialKey {
                remove(ringRadialLines, from: mapView)
                var lines = RangeRingRenderer.lines(viewModel.rings, around: viewModel.center)
                lines += viewModel.radialManager.lines(center: viewModel.center)
                ringRadialLines = add(lines, to: mapView)
                ringRadialKey = radialKey
            }

            // Strip geometry (runway centerline + cones + circuit) per runway —
            // only the toggled strip is added/removed.
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

            // Localizer line per enabled approach.
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
            guard let aircraft = viewModel.aircraft.first else { return }

            // Symbol (leader baked into the image; only position + rotation change).
            let symbol = aircraftAnnotation ?? {
                let a = ImageAnnotation()
                a.image = AircraftSymbol.image()
                a.coordinate = aircraft.position
                aircraftAnnotation = a
                mapView.addAnnotation(a)
                return a
            }()
            symbol.coordinate = aircraft.position
            updateRotation(of: symbol, degrees: aircraft.headingDegrees, on: mapView)

            // Data block — recreate only when the text changes (refreshes the
            // view); otherwise just move it. Image is set before adding so no
            // default pin ever appears.
            let text = aircraft.dataBlock
            let offset = Geo.offset(from: aircraft.position,
                                    distanceMeters: aircraft.labelDistanceMeters,
                                    bearingDegrees: aircraft.labelBearingDegrees)
            if labelAnnotation == nil || lastLabelText != text {
                let previous = labelAnnotation
                let a = ImageAnnotation()
                a.image = AircraftSymbol.label(text)
                a.coordinate = isDraggingLabel ? (previous?.coordinate ?? offset) : offset
                labelAnnotation = a
                mapView.addAnnotation(a)
                if let previous { mapView.removeAnnotation(previous) }
                lastLabelText = text
            } else if !isDraggingLabel {
                labelAnnotation?.coordinate = offset
            }

            // History trail
            syncTrail(aircraft.history, on: mapView)

            // Tether (geographic — redraws itself on zoom, only rebuilt on tick)
            if let label = labelAnnotation {
                updateTether(from: aircraft.position, to: label.coordinate, on: mapView)
            }
        }

        private func syncTrail(_ history: [CLLocationCoordinate2D], on mapView: MLNMapView) {
            if !trailAnnotations.isEmpty {
                mapView.removeAnnotations(trailAnnotations)
                trailAnnotations = []
            }
            for index in history.indices {
                let fraction = history.count > 1 ? Double(index) / Double(history.count - 1) : 1
                let step = Int((fraction * Double(trailIcons.count - 1)).rounded())
                let annotation = ImageAnnotation()
                annotation.image = trailIcons[step]      // set before adding → no default pin
                annotation.coordinate = history[index]
                trailAnnotations.append(annotation)
                mapView.addAnnotation(annotation)
            }
        }

        private func updateTether(from start: CLLocationCoordinate2D,
                                  to end: CLLocationCoordinate2D,
                                  on mapView: MLNMapView) {
            var coords = [start, end]
            tetherSource?.shape = MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
        }

        private func updateRotation(of annotation: ImageAnnotation, degrees: CGFloat, on mapView: MLNMapView) {
            annotation.rotationDegrees = degrees
            if let view = mapView.view(for: annotation) {
                view.transform = CGAffineTransform(rotationAngle: degrees * .pi / 180)
            }
        }

        // MARK: Annotation appearance

        func mapView(_ mapView: MLNMapView, strokeColorForShapeAnnotation annotation: MLNShape) -> UIColor {
            lineStyles[ObjectIdentifier(annotation)]?.color ?? .green
        }

        func mapView(_ mapView: MLNMapView, lineWidthForPolylineAnnotation annotation: MLNPolyline) -> CGFloat {
            lineStyles[ObjectIdentifier(annotation)]?.width ?? 1
        }

        func mapView(_ mapView: MLNMapView, alphaForShapeAnnotation annotation: MLNShape) -> CGFloat {
            1
        }

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            guard let imageAnnotation = annotation as? ImageAnnotation else { return nil }
            let view = MLNAnnotationView(reuseIdentifier: nil)
            // No image → return an empty, transparent view so MapLibre never
            // falls back to a default pin.
            guard let image = imageAnnotation.image else { return view }
            view.frame = CGRect(origin: .zero, size: image.size)
            let imageView = UIImageView(image: image)
            imageView.frame = view.bounds
            view.addSubview(imageView)
            view.transform = CGAffineTransform(rotationAngle: imageAnnotation.rotationDegrees * .pi / 180)
            return view
        }

        // MARK: Data-block dragging

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let mapView else { return }
            let point = gesture.location(in: mapView)

            switch gesture.state {
            case .began:
                if labelContains(point, in: mapView) {
                    panMode = .label
                    isDraggingLabel = true
                } else {
                    panMode = .map
                    lastPanTranslation = .zero
                }

            case .changed:
                switch panMode {
                case .label:
                    guard let label = labelAnnotation, let aircraft = viewModel.aircraft.first else { return }
                    label.coordinate = mapView.convert(point, toCoordinateFrom: mapView)
                    updateTether(from: aircraft.position, to: label.coordinate, on: mapView)

                case .map:
                    // Manual pan: compute the proposed new centre and clamp it to
                    // the 200 NM radius BEFORE applying, so it never overshoots.
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
                if panMode == .label, let aircraft = viewModel.aircraft.first, let label = labelAnnotation {
                    let bearing = Geo.bearing(from: aircraft.position, to: label.coordinate)
                    let distance = Geo.distanceMeters(from: aircraft.position, to: label.coordinate)
                    viewModel.setLabelOffset(for: aircraft.id, bearingDegrees: bearing, distanceMeters: distance)
                }
                isDraggingLabel = false
                panMode = .none

            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        private func labelContains(_ point: CGPoint, in mapView: MLNMapView) -> Bool {
            guard let label = labelAnnotation, let image = label.image else { return false }
            // MapLibre centers annotation views on the coordinate.
            let anchor = mapView.convert(label.coordinate, toPointTo: mapView)
            let rect = CGRect(x: anchor.x - image.size.width / 2,
                              y: anchor.y - image.size.height / 2,
                              width: image.size.width, height: image.size.height)
            return rect.insetBy(dx: -16, dy: -16).contains(point)
        }
    }
}
