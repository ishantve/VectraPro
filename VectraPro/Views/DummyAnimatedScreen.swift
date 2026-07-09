//
//  DummyAnimatedScreen.swift
//  VectraPro
//
//  Interactive demo: floating draggable shapes you can move with a mouse or
//  finger. Also runs a gentle idle animation so the scene feels alive.
//

import SwiftUI

struct DummyAnimatedScreen: View {

    @State private var shapes: [DraggableShape] = DraggableShape.demoSet
    @State private var pulse = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Background gradient
                LinearGradient(
                    colors: [Color(red: 0.05, green: 0.07, blue: 0.15),
                             Color(red: 0.02, green: 0.03, blue: 0.08)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                // Faint dot grid
                GridBackground()
                    .opacity(0.15)

                // Title / hint
                VStack {
                    Text("Drag the shapes")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                    Text("Move them anywhere with your mouse or finger")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(.top, 40)
                .frame(maxHeight: .infinity, alignment: .top)

                // Draggable shapes
                ForEach($shapes) { $shape in
                    ShapeView(shape: shape, pulse: pulse)
                        .position(shape.position)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    shape.position = value.location
                                }
                        )
                }
            }
            .onAppear {
                // Place shapes relative to the actual view size on first layout.
                if !shapes.isEmpty, shapes[0].position == .zero {
                    for i in shapes.indices {
                        shapes[i].position = DraggableShape.initialPositions(in: geo.size)[i]
                    }
                }
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
        }
    }
}

// MARK: - Shape model

struct DraggableShape: Identifiable {
    enum Kind { case circle, square, triangle, capsule, star }

    let id = UUID()
    var kind: Kind
    var color: Color
    var size: CGFloat
    var position: CGPoint = .zero

    static let demoSet: [DraggableShape] = [
        DraggableShape(kind: .circle,   color: .green,  size: 90),
        DraggableShape(kind: .square,   color: .orange, size: 80),
        DraggableShape(kind: .triangle, color: .cyan,   size: 100),
        DraggableShape(kind: .capsule,  color: .pink,   size: 110),
        // DraggableShape(kind: .star,     color: .yellow, size: 90),
    ]

    static func initialPositions(in size: CGSize) -> [CGPoint] {
        let w = size.width, h = size.height
        return [
            CGPoint(x: w * 0.25, y: h * 0.35),
            CGPoint(x: w * 0.55, y: h * 0.30),
            CGPoint(x: w * 0.75, y: h * 0.45),
            CGPoint(x: w * 0.35, y: h * 0.65),
            CGPoint(x: w * 0.65, y: h * 0.70),
        ]
    }
}

// MARK: - Shape rendering

private struct ShapeView: View {
    let shape: DraggableShape
    let pulse: Bool

    var body: some View {
        shapeBody
            .frame(width: shape.size, height: shape.size)
            .foregroundStyle(
                LinearGradient(
                    colors: [shape.color, shape.color.opacity(0.6)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .shadow(color: shape.color.opacity(0.5), radius: pulse ? 18 : 8)
            .scaleEffect(pulse ? 1.04 : 0.98)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var shapeBody: some View {
        switch shape.kind {
        case .circle:   Circle()
        case .square:   RoundedRectangle(cornerRadius: 16, style: .continuous)
        case .triangle: Triangle()
        case .capsule:  Capsule()
        case .star:     Star(points: 5)
        }
    }
}

// MARK: - Custom shapes

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

private struct Star: Shape {
    let points: Int
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.42
        var p = Path()
        let step = Double.pi / Double(points)
        for i in 0..<(points * 2) {
            let r = i.isMultiple(of: 2) ? outer : inner
            let angle = step * Double(i) - .pi / 2
            let pt = CGPoint(x: center.x + CGFloat(cos(angle)) * r,
                             y: center.y + CGFloat(sin(angle)) * r)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

private struct GridBackground: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 40
            let dot = Path(ellipseIn: CGRect(x: 0, y: 0, width: 2, height: 2))
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    context.fill(dot.offsetBy(dx: x, dy: y),
                                 with: .color(.white))
                    x += spacing
                }
                y += spacing
            }
        }
    }
}

#Preview {
    DummyAnimatedScreen()
}
