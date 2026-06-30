//
//  FixSymbol.swift
//  VectraPro
//
//  Icon for waypoint fixes — uses the "triangle" asset, resized for the map.
//

import UIKit

enum FixSymbol {

    static let offWhite = UIColor(white: 0.93, alpha: 1.0)

    /// The "triangle" asset (waypoint fixes). Falls back to a drawn triangle.
    static func triangle(size: CGFloat = 24) -> UIImage {
        resized(named: "triangle", size: size) ?? drawnTriangle(size: size)
    }

    /// The "holding" asset (holding fixes), tinted off-white.
    static func holding(size: CGFloat = 20) -> UIImage {
        guard let image = resized(named: "holding", size: size) else { return drawnTriangle(size: size) }
        return image.withTintColor(offWhite, renderingMode: .alwaysOriginal)
    }

    /// An icon with the fix name (off-white, all-caps) below it, centered.
    static func marker(name: String, icon: UIImage) -> UIImage {
        let label = name.uppercased()
        let font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: offWhite]
        let textSize = (label as NSString).size(withAttributes: attrs)
        let gap: CGFloat = 2

        let width = max(icon.size.width, textSize.width)
        let height = icon.size.height + gap + textSize.height
        let canvas = CGSize(width: ceil(width), height: ceil(height))

        return UIGraphicsImageRenderer(size: canvas).image { _ in
            let iconRect = CGRect(x: (canvas.width - icon.size.width) / 2, y: 0,
                                  width: icon.size.width, height: icon.size.height)
            icon.draw(in: iconRect)

            let textRect = CGRect(x: (canvas.width - textSize.width) / 2,
                                  y: icon.size.height + gap,
                                  width: textSize.width, height: textSize.height)
            (label as NSString).draw(in: textRect, withAttributes: attrs)
        }
    }

    /// Load a named asset and resize it to fit `size` (aspect preserved).
    private static func resized(named: String, size: CGFloat) -> UIImage? {
        guard let base = UIImage(named: named) else { return nil }
        let aspect = base.size.height == 0 ? 1 : base.size.width / base.size.height
        var target = CGSize(width: size, height: size)
        if aspect > 1 { target.height = size / aspect } else { target.width = size * aspect }
        return UIGraphicsImageRenderer(size: target).image { _ in
            base.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    private static func drawnTriangle(size: CGFloat, color: UIColor = UIColor.green.withAlphaComponent(0.9)) -> UIImage {
        let canvas = CGSize(width: size, height: size)
        return UIGraphicsImageRenderer(size: canvas).image { _ in
            let inset: CGFloat = 2
            let path = UIBezierPath()
            path.move(to: CGPoint(x: size / 2, y: inset))
            path.addLine(to: CGPoint(x: size - inset, y: size - inset))
            path.addLine(to: CGPoint(x: inset, y: size - inset))
            path.close()
            color.setStroke()
            path.lineWidth = 1.6
            path.stroke()
        }
    }
}
