# GeoNavKit

[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-iOS%2015%2B%20%7C%20macOS%2012%2B-blue.svg)](#requirements)
[![SPM](https://img.shields.io/badge/SwiftPM-compatible-brightgreen.svg)](https://swift.org/package-manager)
[![License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](LICENSE)

Lightweight, dependency-free **geospatial math** for Swift. Great-circle
bearing/distance/destination, nautical-mile conversion, geographic shape
polygons, and path resampling — all as pure functions over
`CLLocationCoordinate2D`.

No third-party dependencies. Just `Foundation` + `CoreLocation`. Everything is
a `static` function on a namespace `enum`, so there is no state to manage.

## Features

- **`Geo`** — great-circle navigation math
  - `bearing(from:to:)` — initial bearing (0–360°)
  - `distanceMeters(from:to:)` — great-circle distance in meters
  - `offset(from:distanceMeters:bearingDegrees:)` — destination point
- **`Distance`** — nautical-mile ↔ meter conversion (`1 NM = 1852 m`)
- **`ColliderGeometry`** — closed coordinate rings for geo shapes
  - `circle(center:radiusNM:steps:)` — a circle polygon (geo-fence / range ring)
  - `diamond(center:forwardNM:sideNM:headingDeg:)` — heading-aligned diamond
  - `noseRect(center:forwardNM:sideNM:headingDeg:)` — heading-aligned rectangle
- **`TrailSampler`** — dots along a recent path (breadcrumbs / trails)
  - `equalSpaced(from:count:)` — evenly spread over the path
  - `fixedSpaced(from:count:spacingNM:)` — fixed NM spacing, projected backward

## Installation

### Swift Package Manager

Add the dependency in Xcode via **File → Add Package Dependencies…** with the
repository URL, or in your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/<your-org>/GeoNavKit.git", from: "1.0.0")
],
targets: [
    .target(name: "YourTarget", dependencies: ["GeoNavKit"])
]
```

## Usage

```swift
import CoreLocation
import GeoNavKit

let jfk = CLLocationCoordinate2D(latitude: 40.6413, longitude: -73.7781)
let lax = CLLocationCoordinate2D(latitude: 33.9416, longitude: -118.4085)

// Bearing & distance
let heading  = Geo.bearing(from: jfk, to: lax)          // ≈ 274°
let meters   = Geo.distanceMeters(from: jfk, to: lax)   // ≈ 3,983,000 m

// Destination point: 10 NM north-east of JFK
let waypoint = Geo.offset(from: jfk,
                          distanceMeters: 10 * Distance.metersPerNauticalMile,
                          bearingDegrees: 45)

// Unit conversion
let meters20NM = 20.0.nauticalMilesToMeters              // 37,040 m

// A 5 NM geo-fence ring around JFK
let ring = ColliderGeometry.circle(center: jfk, radiusNM: 5)

// Trail dots: 6 evenly-spaced points along a recent track
let dots = TrailSampler.equalSpaced(from: recentPositions, count: 6)
```

## Requirements

| | |
|---|---|
| Swift | 5.9+ |
| Platforms | iOS 15+, macOS 12+ |
| Dependencies | none (Foundation, CoreLocation) |

## Notes on accuracy

- `distanceMeters` uses `CLLocation.distance(from:)` (ellipsoidal / WGS-84).
- `offset` uses a spherical model (mean Earth radius 6,371 km). Over short
  ranges the two agree to within ~0.1%; for sub-meter precision at large
  distances, prefer a dedicated geodesic library.

## License

GeoNavKit is available under the MIT license. See [LICENSE](LICENSE).
