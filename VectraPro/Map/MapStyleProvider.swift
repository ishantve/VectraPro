//
//  MapStyleProvider.swift
//  VectraPro
//
//  Provides the dark, label-free map style.
//

import GoogleMaps

enum MapStyleProvider {

    /// A fully black map with all labels hidden.
    static func darkStyle() -> GMSMapStyle? {
        let json = """
        [
          { "elementType": "labels", "stylers": [{ "visibility": "off" }] },
          { "elementType": "geometry", "stylers": [{ "color": "#000000" }] },
          { "featureType": "road", "elementType": "geometry", "stylers": [{ "color": "#1a1a1a" }] },
          { "featureType": "water", "elementType": "geometry", "stylers": [{ "color": "#000000" }] }
        ]
        """
        do {
            return try GMSMapStyle(jsonString: json)
        } catch {
            print("Failed to apply map style: \(error)")
            return nil
        }
    }
}
