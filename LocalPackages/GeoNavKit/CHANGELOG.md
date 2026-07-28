# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/) and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-07-28

### Added
- `Geo` — great-circle `bearing(from:to:)`, `distanceMeters(from:to:)`, and
  `offset(from:distanceMeters:bearingDegrees:)`.
- `Distance` — `metersPerNauticalMile` constant and the
  `Double.nauticalMilesToMeters` convenience.
- `ColliderGeometry` — `circle`, `diamond`, and `noseRect` coordinate-ring
  builders.
- `TrailSampler` — `equalSpaced` and `fixedSpaced` path-resampling helpers.
- Unit test suite covering bearing, distance, offset round-trips, and shape
  geometry.
