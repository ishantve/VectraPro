//
//  MeasurementRenderer.swift
//  VectraPro
//
//  Pure rendering utility for the distance-measurement overlay. It generates
//  UIImages only. It knows nothing about any map SDK (Google Maps / MapLibre),
//  markers, annotations, overlays, map views, gestures, or controller state —
//  each radar controller places these images into its own map. Dependency
//  direction is one-way: controllers → MeasurementRenderer, never the reverse.
//
//  Matches the existing renderer pattern (ZoneRenderer, RangeRingRenderer,
//  RunwayRenderer, …). Image code moved verbatim from RadarMapController with no
//  visual change.
//

import UIKit

enum MeasurementRenderer {

    /// White dot marking a measurement endpoint.
    static func endpointImage() -> UIImage {
        let size: CGFloat = 10
        UIGraphicsBeginImageContextWithOptions(CGSize(width: size, height: size), false, 0)
        UIColor.white.setFill()
        UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: size - 2, height: size - 2)).fill()
        let img = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return img
    }

    /// Rounded dark chip showing the measured distance text (e.g. "12.3 NM").
    static func labelImage(_ text: String) -> UIImage {
        let font  = UIFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let pad   = CGSize(width: 12, height: 6)
        let rect  = CGRect(origin: .zero,
                           size: CGSize(width: textSize.width + pad.width,
                                        height: textSize.height + pad.height))
        UIGraphicsBeginImageContextWithOptions(rect.size, false, 3)
        UIColor.black.withAlphaComponent(0.72).setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: 4).fill()
        UIColor.white.withAlphaComponent(0.35).setStroke()
        UIBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 4).stroke()
        (text as NSString).draw(in: rect.insetBy(dx: pad.width / 2, dy: pad.height / 2),
                                withAttributes: attrs)
        let img = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return img
    }
}
