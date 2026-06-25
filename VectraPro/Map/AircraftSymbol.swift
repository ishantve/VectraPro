//
//  AircraftSymbol.swift
//  VectraPro
//
//  Radar aircraft visuals: the diamond/nose/tail symbol, history dots, and
//  the data-block label image.
//

import UIKit

enum AircraftSymbol {

    static let color = UIColor.white

    /// The aircraft symbol — diamond body, a small nose just ahead, and a
    /// short tail behind. Sized small to read like a real radar target. Drawn
    /// pointing "up" (north); the marker is rotated to the heading.
    static func image() -> UIImage {
        let size = CGSize(width: 22, height: 28)
        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.image { _ in
            color.setStroke()
            color.setFill()

            let cx: CGFloat = 11
            let cy: CGFloat = 14      // diamond centre
            let half: CGFloat = 5.5   // diamond half-size

            // Nose — tiny triangle sitting right on the front of the diamond.
            let nose = UIBezierPath()
            nose.move(to: CGPoint(x: cx, y: cy - half - 2))        // tip
            nose.addLine(to: CGPoint(x: cx - 2, y: cy - (2 * half)))     // base on diamond top
            // nose.addLine(to: CGPoint(x: cx + 2, y: cy - (2 * half)))
            nose.close()
            nose.fill()

            // Diamond — the aircraft body.
            let diamond = UIBezierPath()
            diamond.move(to: CGPoint(x: cx, y: cy - half))
            diamond.addLine(to: CGPoint(x: cx + half, y: cy))
            diamond.addLine(to: CGPoint(x: cx, y: cy + half))
            diamond.addLine(to: CGPoint(x: cx - half, y: cy))
            diamond.close()
            diamond.lineWidth = 1.5
            diamond.stroke()

            // Tail — short line behind the body with a small fin.
            let tail = UIBezierPath()
            tail.move(to: CGPoint(x: cx, y: cy + half))
            tail.addLine(to: CGPoint(x: cx, y: 26))
            tail.lineWidth = 1.5
            tail.stroke()

            // let fin = UIBezierPath()
            // fin.move(to: CGPoint(x: cx - 4, y: 24))
            // fin.addLine(to: CGPoint(x: cx + 4, y: 24))
            // fin.lineWidth = 1.5
            // fin.stroke()
        }
    }

    /// A history-trail dot. `fraction` runs 0 (oldest, far tail — small & faint)
    /// to 1 (newest, nearest the aircraft — larger & brighter).
    static func trailDot(fraction: Double) -> UIImage {
        let diameter = 2.0 + 4.0 * fraction        // 2 … 6 pt
        let alpha = 0.25 + 0.70 * fraction          // 0.25 … 0.95
        let size = CGSize(width: diameter, height: diameter)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            color.withAlphaComponent(alpha).setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }
    }

    /// The data-block text image (left-padded so it sits beside the symbol).
    static func label(_ text: String) -> UIImage {
        let label = UILabel()
        label.numberOfLines = 0
        label.text = text
        label.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        label.textColor = color
        label.sizeToFit()

        let leftPad: CGFloat = 8
        let size = CGSize(width: label.bounds.width + leftPad, height: label.bounds.height)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            label.drawText(in: CGRect(x: leftPad, y: 0,
                                      width: label.bounds.width,
                                      height: label.bounds.height))
        }
    }
}
