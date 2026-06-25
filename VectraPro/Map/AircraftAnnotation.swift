//
//  AircraftAnnotation.swift
//  VectraPro
//
//  Owns the map overlays for one aircraft (symbol, leader line, history dots,
//  and a draggable data block tethered by a faded dashed line) and updates
//  them in place each tick to avoid flicker.
//

import CoreLocation
import GoogleMaps
import QuartzCore

final class AircraftAnnotation {

    private let symbol = GMSMarker()
    let label = GMSMarker()
    private let leader = GMSPolyline()
    private let tether = GMSPolyline()
    private var trailDots: [GMSMarker] = []

    private static let trailSteps = 8
    private let trailIcons: [UIImage] = (0..<trailSteps).map {
        AircraftSymbol.trailDot(fraction: Double($0) / Double(trailSteps - 1))
    }
    private var lastLabelText = ""
    private(set) var labelSize: CGSize = .zero

    /// While the user is dragging the data block we stop repositioning it.
    var isDraggingLabel = false

    init(on mapView: GMSMapView) {
        symbol.icon = AircraftSymbol.image()
        symbol.groundAnchor = CGPoint(x: 0.5, y: 0.5)
        symbol.isFlat = true
        symbol.isTappable = false
        symbol.map = mapView

        // Data block — anchored at its left edge (text to the right). Dragging
        // is handled manually via a pan gesture (see GoogleMapView.Coordinator).
        label.groundAnchor = CGPoint(x: 0, y: 0.5)
        label.map = mapView

        leader.strokeColor = AircraftSymbol.color
        leader.strokeWidth = 1.5
        leader.map = mapView

        tether.strokeColor = UIColor.white.withAlphaComponent(0.5)   // fallback if spans fail
        tether.strokeWidth = 1.5
        tether.map = mapView
    }

    /// Lay out the leader line at a constant on-screen length in the heading
    /// direction, so it doesn't scale with zoom. Recomputed on every camera
    /// change as well as each tick.
    func layoutLeader(aircraft: Aircraft, on mapView: GMSMapView) {
        let leaderScreenLength = 40.0
        let start = mapView.projection.point(for: aircraft.position)
        let angle = (aircraft.headingDegrees - mapView.camera.bearing) * .pi / 180
        let dx = sin(angle) * leaderScreenLength
        let dy = -cos(angle) * leaderScreenLength
        let end = CGPoint(x: start.x + CGFloat(dx), y: start.y + CGFloat(dy))

        let path = GMSMutablePath()
        path.add(aircraft.position)
        path.add(mapView.projection.coordinate(for: end))
        leader.path = path
    }

    /// Whether `point` (in the map view) is on the data block.
    func labelContains(_ point: CGPoint, in mapView: GMSMapView) -> Bool {
        let anchor = mapView.projection.point(for: label.position)
        let width = max(labelSize.width, 24)
        let height = max(labelSize.height, 24)
        let rect = CGRect(x: anchor.x, y: anchor.y - height / 2, width: width, height: height)
        return rect.insetBy(dx: -14, dy: -14).contains(point)
    }

    /// Move the data block to a coordinate (during a manual drag). Marker
    /// position changes animate by default; disable that so the block tracks
    /// the finger with no lag.
    func moveLabel(to coordinate: CLLocationCoordinate2D,
                   aircraftPosition: CLLocationCoordinate2D) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        label.position = coordinate
        updateTether(from: aircraftPosition, to: coordinate)
        CATransaction.commit()
    }

    func update(with aircraft: Aircraft, on mapView: GMSMapView) {
        // Symbol
        symbol.position = aircraft.position
        symbol.rotation = aircraft.headingDegrees

        // Data block text (regenerate image only when it changes)
        if aircraft.dataBlock != lastLabelText {
            let image = AircraftSymbol.label(aircraft.dataBlock)
            label.icon = image
            labelSize = image.size
            lastLabelText = aircraft.dataBlock
        }

        // Keep the block at its stored offset, unless the user is dragging it.
        if !isDraggingLabel {
            label.position = Geo.offset(from: aircraft.position,
                                        distanceMeters: aircraft.labelDistanceMeters,
                                        bearingDegrees: aircraft.labelBearingDegrees)
        }

        // Leader line — fixed on-screen length in the heading direction
        // (does not grow when zooming in).
        layoutLeader(aircraft: aircraft, on: mapView)

        // Tether — faded dashed line from the aircraft to the data block.
        updateTether(from: aircraft.position, to: label.position)

        // History trail — reuse a pool of dot markers, tapering from the
        // oldest point (index 0, far tail) to the newest (nearest aircraft).
        let history = aircraft.history
        while trailDots.count < history.count {
            let dot = GMSMarker()
            dot.groundAnchor = CGPoint(x: 0.5, y: 0.5)
            dot.isTappable = false
            trailDots.append(dot)
        }
        for (index, dot) in trailDots.enumerated() {
            guard index < history.count else { dot.map = nil; continue }
            let fraction = history.count > 1 ? Double(index) / Double(history.count - 1) : 1
            let step = Int((fraction * Double(trailIcons.count - 1)).rounded())
            dot.icon = trailIcons[step]
            dot.position = history[index]
            dot.map = mapView
        }
    }

    /// Redraw the dashed tether between the aircraft and the data block.
    func updateTether(from start: CLLocationCoordinate2D,
                      to end: CLLocationCoordinate2D) {
        let path = GMSMutablePath()
        path.add(start)
        path.add(end)
        tether.path = path

        // Fixed dash/gap length so dashes stay the same size as the tether is
        // stretched — only the number of dashes grows.
        let dashMeters = 120.0
        let solid = GMSStrokeStyle.solidColor(UIColor.white.withAlphaComponent(0.55))
        let gap = GMSStrokeStyle.solidColor(.clear)
        tether.spans = GMSStyleSpans(path, [solid, gap],
                                     [NSNumber(value: dashMeters), NSNumber(value: dashMeters)],
                                     .rhumb)
    }

    func remove() {
        symbol.map = nil
        label.map = nil
        leader.map = nil
        tether.map = nil
        trailDots.forEach { $0.map = nil }
    }
}
