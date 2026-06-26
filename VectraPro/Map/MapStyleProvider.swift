//
//  MapStyleProvider.swift
//  VectraPro
//
//  Provides a dark OpenStreetMap raster style for MapLibre, written to a temp
//  file whose URL is used as the map's styleURL.
//

import Foundation

enum MapStyleProvider {

    /// Dark OSM raster style (OSM data, CARTO dark rendering) — good contrast
    /// for the green/white radar overlays.
    static func darkOSMStyleURL() -> URL {
        let json = """
        {
          "version": 8,
          "sources": {
            "osm": {
              "type": "raster",
              "tiles": [
                "https://a.basemaps.cartocdn.com/dark_nolabels/{z}/{x}/{y}.png",
                "https://b.basemaps.cartocdn.com/dark_nolabels/{z}/{x}/{y}.png",
                "https://c.basemaps.cartocdn.com/dark_nolabels/{z}/{x}/{y}.png"
              ],
              "tileSize": 256,
              "attribution": "© OpenStreetMap contributors, © CARTO"
            }
          },
          "layers": [
            { "id": "background", "type": "background", "paint": { "background-color": "#000000" } },
            { "id": "osm", "type": "raster", "source": "osm" }
          ]
        }
        """

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vectra_osm_dark_style.json")
        try? json.data(using: .utf8)?.write(to: url)
        return url
    }
}
