//
//  ObjectCanvas.swift
//  VectraPro
//
//  A drop-enabled canvas that shows the objects currently on one display and
//  lets them be dragged across windows. Each object carries an origin badge so
//  you can see which display it was generated on.
//

import SwiftUI

struct ObjectCanvas: View {

    let display: DisplayID
    @ObservedObject private var store = ObjectsStore.shared

    var body: some View {
        ZStack {
            // Background
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.07, blue: 0.15),
                         Color(red: 0.02, green: 0.03, blue: 0.08)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )

            GridBackground().opacity(0.12)

            // Objects on this display
            ForEach(store.objects(on: display)) { obj in
                ObjectMark(object: obj, isSelected: store.selectedID == obj.id)
                    .position(obj.position)
                    // Tap to select.
                    .onTapGesture { store.select(obj.id) }
                    // Continuous in-window movement with mouse / finger.
                    .simultaneousGesture(
                        DragGesture(coordinateSpace: .named("canvas"))
                            .onChanged {
                                store.select(obj.id)
                                store.setPosition(id: obj.id, $0.location)
                            }
                    )
                    // Press-and-hold lift for cross-window drag-and-drop.
                    .draggable(obj) {
                        ObjectMark(object: obj, isSelected: false)
                            .frame(width: obj.size, height: obj.size)
                    }
            }
        }
        .coordinateSpace(name: "canvas")
        .contentShape(Rectangle())
        .dropDestination(for: DemoObject.self) { items, location in
            for item in items {
                store.move(id: item.id, to: display, at: location)
            }
            return true
        }
    }
}

// MARK: - Single object mark

private struct ObjectMark: View {
    let object: DemoObject
    var isSelected: Bool = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            shapeBody
                .frame(width: object.size, height: object.size)
                .foregroundStyle(
                    LinearGradient(colors: [object.color, object.color.opacity(0.6)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .shadow(color: object.color.opacity(0.5), radius: 10)
                // Selection ring
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.white, lineWidth: isSelected ? 3 : 0)
                        .padding(-8)
                        .opacity(isSelected ? 1 : 0)
                )

            // Origin badge — which display generated this object
            Text(object.origin.tag)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
                .frame(width: 20, height: 20)
                .background(object.origin.tagColor, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1))
                .offset(x: 6, y: -6)
        }
        .frame(width: object.size, height: object.size)
    }

    @ViewBuilder
    private var shapeBody: some View {
        switch object.shape {
        case .circle:   Circle()
        case .square:   RoundedRectangle(cornerRadius: 16, style: .continuous)
        case .triangle: Triangle()
        case .capsule:  Capsule()
        }
    }
}

// MARK: - Triangle shape

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

#Preview {
    ObjectCanvas(display: .main)
}
