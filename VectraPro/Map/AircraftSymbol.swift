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

    /// The aircraft symbol — hollow diamond body, a tiny nose, a short tail and
    /// a forward leader line, all baked into one image so it stays a fixed
    /// on-screen size and rotates as a whole. Drawn pointing "up" (north); the
    /// annotation view is rotated to the heading.
    static func image() -> UIImage {
        let side: CGFloat = 100
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))

        return renderer.image { _ in
            color.setStroke()
            color.setFill()

            let cx = side / 2          // symbol sits at the centre = aircraft position
            let cy = side / 2
            let half: CGFloat = 5.5
            let leaderLength: CGFloat = 40

            // Leader (velocity vector) — forward from the body.
            let leader = UIBezierPath()
            leader.move(to: CGPoint(x: cx, y: cy - half))
            leader.addLine(to: CGPoint(x: cx, y: cy - leaderLength))
            leader.lineWidth = 1.5
            leader.stroke()

            // Nose — tiny triangle on the front of the diamond.
            let nose = UIBezierPath()
            nose.move(to: CGPoint(x: cx, y: cy - half - 2))
            nose.addLine(to: CGPoint(x: cx - 2, y: cy - half))
            nose.addLine(to: CGPoint(x: cx + 2, y: cy - half))
            nose.close()
            nose.fill()

            // Diamond body (hollow).
            let diamond = UIBezierPath()
            diamond.move(to: CGPoint(x: cx, y: cy - half))
            diamond.addLine(to: CGPoint(x: cx + half, y: cy))
            diamond.addLine(to: CGPoint(x: cx, y: cy + half))
            diamond.addLine(to: CGPoint(x: cx - half, y: cy))
            diamond.close()
            diamond.lineWidth = 1.5
            diamond.stroke()

            // Tail — short line behind the body.
            let tail = UIBezierPath()
            tail.move(to: CGPoint(x: cx, y: cy + half))
            tail.addLine(to: CGPoint(x: cx, y: cy + half + 12))
            tail.lineWidth = 1.5
            tail.stroke()
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
