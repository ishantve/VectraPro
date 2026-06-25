//
//  GoogleMapView.swift
//  VectraPro
//
//  Radar map: range rings, runways, and tap-to-draw runway design.
//

import GoogleMaps
import SwiftUI

struct GoogleMapView: UIViewRepresentable {

    @ObservedObject var viewModel: MapViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeUIView(context: Context) -> GMSMapView {
        let camera = GMSCameraPosition.camera(
            withTarget: viewModel.center,
            zoom: viewModel.defaultZoom
        )

        let mapView = GMSMapView(frame: .zero, camera: camera)
        mapView.mapStyle = MapStyleProvider.darkStyle()
        mapView.delegate = context.coordinator
        context.coordinator.mapView = mapView
        configureSettings(mapView)

        // Manual drag for the aircraft data block.
        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLabelPan(_:))
        )
        pan.delegate = context.coordinator
        mapView.addGestureRecognizer(pan)

        RangeRingRenderer.render(
            viewModel.rings,
            around: viewModel.center,
            on: mapView
        )

        return mapView
    }

    func updateUIView(_ uiView: GMSMapView, context: Context) {
        context.coordinator.applyZoomLimit(on: uiView)
        context.coordinator.sync(on: uiView)
    }

    // MARK: - Settings

    private func configureSettings(_ mapView: GMSMapView) {
        mapView.isMyLocationEnabled = false

        mapView.settings.myLocationButton = false
        mapView.settings.compassButton = true

        mapView.settings.zoomGestures = true
        mapView.settings.scrollGestures = true
        mapView.settings.rotateGestures = true
        mapView.settings.tiltGestures = false
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, GMSMapViewDelegate, UIGestureRecognizerDelegate {

        weak var mapView: GMSMapView?

        private let viewModel: MapViewModel
        private var runwayOverlays: [UUID: [GMSOverlay]] = [:]
        private var stripOverlays: [UUID: [GMSOverlay]] = [:]
        private var localizerOverlays: [ApproachID: [GMSOverlay]] = [:]
        private var aircraftAnnotations: [UUID: AircraftAnnotation] = [:]
        private var pendingMarker: GMSMarker?
        private var draggingLabelID: UUID?
        private var didLimitZoom = false

        init(viewModel: MapViewModel) {
            self.viewModel = viewModel
        }

        /// Lock zoom-out so no more than a 70 NM radius is ever visible, and
        /// start at that fit. Runs once, after the map has a real size.
        func applyZoomLimit(on mapView: GMSMapView) {
            guard !didLimitZoom,
                  mapView.bounds.width > 0,
                  mapView.bounds.height > 0 else { return }

            let radius = 70 * Distance.metersPerNauticalMile
            let center = viewModel.center
            let bounds = GMSCoordinateBounds(
                coordinate: Geo.offset(from: center, distanceMeters: radius, bearingDegrees: 0),
                coordinate: Geo.offset(from: center, distanceMeters: radius, bearingDegrees: 180)
            )
            .includingCoordinate(Geo.offset(from: center, distanceMeters: radius, bearingDegrees: 90))
            .includingCoordinate(Geo.offset(from: center, distanceMeters: radius, bearingDegrees: 270))

            if let camera = mapView.camera(for: bounds, insets: .zero) {
                mapView.setMinZoom(camera.zoom, maxZoom: kGMSMaxZoomLevel)
                mapView.camera = camera
            }
            didLimitZoom = true
        }

        func mapView(_ mapView: GMSMapView, didTapAt coordinate: CLLocationCoordinate2D) {
            viewModel.handleTap(at: coordinate)
        }

        // Keep leader lines a constant on-screen length while zooming/panning.
        func mapView(_ mapView: GMSMapView, didChange position: GMSCameraPosition) {
            for aircraft in viewModel.aircraft {
                aircraftAnnotations[aircraft.id]?.layoutLeader(aircraft: aircraft, on: mapView)
            }
        }

        // MARK: Data-block dragging (manual)

        @objc func handleLabelPan(_ gesture: UIPanGestureRecognizer) {
            guard let mapView else { return }
            let point = gesture.location(in: mapView)

            switch gesture.state {
            case .began:
                if let entry = labelEntry(at: point, in: mapView) {
                    draggingLabelID = entry.id
                    entry.annotation.isDraggingLabel = true
                    mapView.settings.scrollGestures = false   // don't pan the map
                }

            case .changed:
                guard let id = draggingLabelID,
                      let annotation = aircraftAnnotations[id],
                      let aircraft = viewModel.aircraft.first(where: { $0.id == id }) else { return }
                annotation.moveLabel(to: mapView.projection.coordinate(for: point),
                                     aircraftPosition: aircraft.position)

            case .ended, .cancelled, .failed:
                if let id = draggingLabelID,
                   let annotation = aircraftAnnotations[id],
                   let aircraft = viewModel.aircraft.first(where: { $0.id == id }) {
                    let dropped = mapView.projection.coordinate(for: point)
                    let bearing = Geo.bearing(from: aircraft.position, to: dropped)
                    let distance = Geo.distanceMeters(from: aircraft.position, to: dropped)
                    annotation.isDraggingLabel = false
                    viewModel.setLabelOffset(for: id, bearingDegrees: bearing, distanceMeters: distance)
                }
                draggingLabelID = nil
                mapView.settings.scrollGestures = true

            default:
                break
            }
        }

        /// Only begin our pan when the touch starts on a data block; otherwise
        /// let the map handle panning.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let mapView, gestureRecognizer is UIPanGestureRecognizer else { return true }
            let point = gestureRecognizer.location(in: mapView)
            return labelEntry(at: point, in: mapView) != nil
        }

        // Allow our pan to run alongside the map's own gesture recognizers,
        // otherwise the map claims the touch and the block never drags.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        private func labelEntry(at point: CGPoint,
                                in mapView: GMSMapView) -> (id: UUID, annotation: AircraftAnnotation)? {
            for (id, annotation) in aircraftAnnotations where annotation.labelContains(point, in: mapView) {
                return (id, annotation)
            }
            return nil
        }

        /// An enabled strip (either threshold on) shows its runway centerline,
        /// both-end cones and the circuit. The localizer centerline + range
        /// markers appear only for the specific enabled threshold(s).
        func sync(on mapView: GMSMapView) {
            let enabled = viewModel.enabledApproaches
            let enabledStripIDs = Set(enabled.map(\.runwayID))

            // Runway centerlines — for enabled strips.
            for (id, overlays) in runwayOverlays where !enabledStripIDs.contains(id) {
                overlays.forEach { $0.map = nil }
                runwayOverlays[id] = nil
            }
            for runway in viewModel.runways
            where enabledStripIDs.contains(runway.id) && runwayOverlays[runway.id] == nil {
                runwayOverlays[runway.id] = RunwayRenderer.draw(runway, on: mapView)
            }

            // Strip geometry (both cones + circuit) — for enabled strips.
            for (id, overlays) in stripOverlays where !enabledStripIDs.contains(id) {
                overlays.forEach { $0.map = nil }
                stripOverlays[id] = nil
            }
            for runway in viewModel.runways
            where enabledStripIDs.contains(runway.id) && stripOverlays[runway.id] == nil {
                stripOverlays[runway.id] = LocalizerRenderer.drawStripGeometry(runway: runway, on: mapView)
            }

            // Localizer line + markers — only for enabled thresholds.
            for (id, overlays) in localizerOverlays where !enabled.contains(id) {
                overlays.forEach { $0.map = nil }
                localizerOverlays[id] = nil
            }
            for approach in enabled where localizerOverlays[approach] == nil {
                guard let runway = viewModel.runway(for: approach.runwayID) else { continue }
                localizerOverlays[approach] = LocalizerRenderer.drawLocalizer(
                    runway: runway,
                    side: approach.side,
                    on: mapView
                )
            }

            syncAircraft(on: mapView)
            syncPendingMarker(on: mapView)
        }

        private func syncAircraft(on mapView: GMSMapView) {
            let currentIDs = Set(viewModel.aircraft.map(\.id))

            for (id, annotation) in aircraftAnnotations where !currentIDs.contains(id) {
                annotation.remove()
                aircraftAnnotations[id] = nil
            }

            for aircraft in viewModel.aircraft {
                let annotation = aircraftAnnotations[aircraft.id] ?? {
                    let new = AircraftAnnotation(on: mapView)
                    aircraftAnnotations[aircraft.id] = new
                    return new
                }()
                annotation.update(with: aircraft, on: mapView)
            }
        }

        private func syncPendingMarker(on mapView: GMSMapView) {
            guard let start = viewModel.pendingStart else {
                pendingMarker?.map = nil
                pendingMarker = nil
                return
            }

            let marker = pendingMarker ?? GMSMarker()
            marker.position = start
            marker.icon = GMSMarker.markerImage(with: .green)
            marker.map = mapView
            pendingMarker = marker
        }
    }
}
