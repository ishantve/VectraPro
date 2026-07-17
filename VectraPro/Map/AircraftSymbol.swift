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

    /// High-resolution render format so symbols/labels stay crisp on a
    /// high-res external display (not just the iPad's own scale).
    static var hiResFormat: UIGraphicsImageRendererFormat {
        let f = UIGraphicsImageRendererFormat.preferred()
        f.scale = 3
        f.opaque = false
        return f
    }

    /// The aircraft symbol — hollow diamond body, a tiny nose, a short tail and
    /// a forward leader line, all baked into one image so it stays a fixed
    /// on-screen size and rotates as a whole. Drawn pointing "up" (north); the
    /// annotation view is rotated to the heading.
    static func image() -> UIImage {
        let side: CGFloat = 100
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: hiResFormat)

        return renderer.image { _ in
            color.setStroke()
            color.setFill()

            let cx = side / 2
            let cy = side / 2
            let half: CGFloat = 5.5
            let leaderLength: CGFloat = 20

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
            tail.addLine(to: CGPoint(x: cx, y: cy + half + 8))
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
        let renderer = UIGraphicsImageRenderer(size: size, format: hiResFormat)
        return renderer.image { context in
            color.withAlphaComponent(alpha).setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Renders the data-block as a 2-column grid with arrow icons after altitude and speed:
    ///   Row 0  callsign              aircraft type
    ///   Row 1  alt (target/current) ↑↓  passing altitude
    ///   Row 2  speed ↑↓             heading
    ///   Row 3  squawk
    ///   Row 4  remarks  (optional)
    static func label(for aircraft: Aircraft, conflictColor: UIColor? = nil) -> UIImage {
        let font  = UIFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        let categoryColor: UIColor = {
            switch aircraft.category {
            case .departure: return UIColor(red: 1.0, green: 0.95, blue: 0.45, alpha: 1.0)
            case .arrival:   return UIColor(red: 1.0, green: 0.65, blue: 0.65, alpha: 1.0)
            case .enroute:   return .white
            }
        }()
        let tint  = conflictColor ?? categoryColor
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tint]

        // col0 = target FL while climbing/descending, else current FL
        // col1 = current FL (passing altitude) while in transit, hidden when reached
        let isManeuvering = aircraft.targetAltitudeFeet != nil
        let altCol0 = isManeuvering
            ? "FL\(Int(aircraft.targetAltitudeFeet! / 100))"
            : "FL\(aircraft.flightLevel)"
        let altCol1 = isManeuvering ? "FL\(aircraft.flightLevel)" : ""
        let heading = String(format: "H%03d", Int(aircraft.headingDegrees.rounded()))
        let speed   = "\(Int(aircraft.speedKnots))"

        var rows: [(String, String)] = [
            (aircraft.callsign, aircraft.aircraftType ?? ""),
            (altCol0,           altCol1),
            (speed,             heading),
            (aircraft.squawk,   ""),
        ]
        if let rem = aircraft.remarks, !rem.isEmpty {
            rows.append((rem, ""))
        }

        // Row 1: altitude arrow goes AFTER col1 (passing altitude).
        // Row 2: speed arrow goes AFTER col0 (speed value), before col1 (heading).
        let altArrow: UIImage? = aircraft.targetAltitudeFeet.flatMap { target in
            UIImage(named: target > aircraft.altitudeFeet ? "upArrow" : "downArrow")
        }
        let spdArrow: UIImage? = aircraft.targetSpeedKnots.flatMap { target in
            UIImage(named: target > aircraft.speedKnots ? "upArrow" : "downArrow")
        }

        func textSize(_ s: String) -> CGSize {
            s.isEmpty ? .zero : (s as NSString).size(withAttributes: attrs)
        }
        let rowH              = ("A" as NSString).size(withAttributes: attrs).height
        let arrowSide         = rowH
        let arrowGap: CGFloat = 4
        let colGap: CGFloat   = 14
        let leftPad: CGFloat  = 8
        let lineSpacing: CGFloat = 3

        let col0W        = rows.map { textSize($0.0).width }.max() ?? 0
        let col1W        = rows.map { textSize($0.1).width }.max() ?? 0
        let spdArrowColW = spdArrow != nil ? (arrowGap + arrowSide) : 0
        let altArrowColW = altArrow != nil ? (arrowGap + arrowSide) : 0

        // col1 x is consistent across all rows; speed-arrow gap is reserved even for rows without it.
        let col1X  = leftPad + col0W + spdArrowColW + colGap
        let totalW = col1X + col1W + CGFloat(altArrowColW)
        let totalH = CGFloat(rows.count) * rowH + CGFloat(rows.count - 1) * lineSpacing

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: totalW, height: totalH), format: hiResFormat)
        return renderer.image { _ in
            for (i, row) in rows.enumerated() {
                let y = CGFloat(i) * (rowH + lineSpacing)

                // col0 — always at leftPad
                if !row.0.isEmpty {
                    (row.0 as NSString).draw(at: CGPoint(x: leftPad, y: y), withAttributes: attrs)
                }

                // Speed arrow (row 2 only): immediately after col0 text
                if i == 2, let arrow = spdArrow {
                    arrow.draw(in: CGRect(x: leftPad + textSize(row.0).width + arrowGap, y: y,
                                         width: arrowSide, height: arrowSide))
                }

                // col1 — consistent x across all rows
                if !row.1.isEmpty {
                    (row.1 as NSString).draw(at: CGPoint(x: col1X, y: y), withAttributes: attrs)
                }

                // Altitude arrow (row 1 only): immediately after col1 text
                if i == 1, let arrow = altArrow {
                    let col1TextW = textSize(row.1).width
                    arrow.draw(in: CGRect(x: col1X + col1TextW + arrowGap, y: y,
                                         width: arrowSide, height: arrowSide))
                }
            }
        }
    }
}
