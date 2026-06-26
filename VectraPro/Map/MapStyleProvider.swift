//
//  MapStyleProvider.swift
//  VectraPro
//
//  Builds dark raster styles for the MapLibre renderer (OpenStreetMap or
//  ArcGIS/Esri), written to a temp file whose URL is used as the map's styleURL.
//

import Foundation

enum MapStyleProvider {

    /// Style URL for a MapLibre-backed provider.
    static func styleURL(for provider: MapProvider) -> URL {
        switch provider {
        case .arcgis:
            // Esri "World Dark Gray Base" is greyer than OSM; darken it heavily
            // (low brightness + opacity) to read pure-black like OpenStreetMap.
            return rasterStyle(
                name: "arcgis_dark",
                tiles: ["https://services.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Dark_Gray_Base/MapServer/tile/{z}/{y}/{x}"],
                attribution: "© Esri",
                opacity: 0.55,
                brightnessMax: 0.3
            )
        default:
            // OpenStreetMap (CARTO dark, no labels), dimmed for a Google-like look.
            return rasterStyle(
                name: "osm_dark",
                tiles: [
                    "https://a.basemaps.cartocdn.com/dark_nolabels/{z}/{x}/{y}.png",
                    "https://b.basemaps.cartocdn.com/dark_nolabels/{z}/{x}/{y}.png",
                    "https://c.basemaps.cartocdn.com/dark_nolabels/{z}/{x}/{y}.png",
                ],
                attribution: "© OpenStreetMap contributors, © CARTO",
                opacity: 0.45
            )
        }
    }

    private static func rasterStyle(name: String,
                                    tiles: [String],
                                    attribution: String,
                                    opacity: Double,
                                    brightnessMax: Double = 1.0) -> URL {
        let tilesJSON = tiles.map { "\"\($0)\"" }.joined(separator: ", ")
        let json = """
        {
          "version": 8,
          "sources": {
            "base": {
              "type": "raster",
              "tiles": [\(tilesJSON)],
              "tileSize": 256,
              "attribution": "\(attribution)"
            }
          },
          "layers": [
            { "id": "background", "type": "background", "paint": { "background-color": "#000000" } },
            { "id": "base", "type": "raster", "source": "base", "paint": { "raster-opacity": \(opacity), "raster-brightness-max": \(brightnessMax) } }
          ]
        }
        """

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vectra_style_\(name).json")
        try? json.data(using: .utf8)?.write(to: url)
        return url
    }
}
