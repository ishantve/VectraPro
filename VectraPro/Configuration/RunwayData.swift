//
//  RunwayData.swift
//  VectraPro
//
//  Seed runway data — Indira Gandhi International Airport (VIDP).
//

import CoreLocation

enum RunwayData {

    static let igiAirport: [Runway] = [
        Runway(
            endA: RunwayThreshold(designator: "09", coordinate: CLLocationCoordinate2D(latitude: 28.5705, longitude: 77.0882)),
            endB: RunwayThreshold(designator: "27", coordinate: CLLocationCoordinate2D(latitude: 28.5700, longitude: 77.1153)),
            lengthMeters: 2816
        ),
        Runway(
            endA: RunwayThreshold(designator: "10", coordinate: CLLocationCoordinate2D(latitude: 28.5672, longitude: 77.0848)),
            endB: RunwayThreshold(designator: "28", coordinate: CLLocationCoordinate2D(latitude: 28.5587, longitude: 77.1224)),
            lengthMeters: 3813
        ),
        Runway(
            endA: RunwayThreshold(designator: "11R", coordinate: CLLocationCoordinate2D(latitude: 28.5458, longitude: 77.0718)),
            endB: RunwayThreshold(designator: "29L", coordinate: CLLocationCoordinate2D(latitude: 28.5408, longitude: 77.0950)),
            lengthMeters: 4430
        ),
        Runway(
            endA: RunwayThreshold(designator: "11L", coordinate: CLLocationCoordinate2D(latitude: 28.5563, longitude: 77.0633)),
            endB: RunwayThreshold(designator: "29R", coordinate: CLLocationCoordinate2D(latitude: 28.5513, longitude: 77.0864)),
            lengthMeters: 4400
        ),
    ]
}
