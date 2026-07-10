//
//  DemoObject.swift
//  VectraPro
//
//  A draggable demo object that can be moved BETWEEN windows/displays via the
//  system drag-and-drop (Transferable). Each object remembers the display it
//  was originally generated on (`origin`) so we can always tell its source,
//  and tracks the display it currently sits on (`display`) + its position.
//

import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers
import Combine

// MARK: - Custom drag type

extension UTType {
    static let demoObject = UTType(exportedAs: "com.vectrapro.demoobject")
}

// MARK: - Shape kinds

enum ObjShape: String, Codable, CaseIterable {
    case circle, square, triangle, capsule
}

// MARK: - Display identifiers

enum DisplayID: String, Codable {
    case main        = "Main"
    case extended    = "Extended"
    case interactive = "Interactive"

    /// Short badge shown on each object.
    var tag: String {
        switch self {
        case .main:        return "M"
        case .extended:    return "E"
        case .interactive: return "I"
        }
    }

    var tagColor: Color {
        switch self {
        case .main:        return .green
        case .extended:    return .cyan
        case .interactive: return .orange
        }
    }
}

// MARK: - Model

struct DemoObject: Identifiable, Codable, Transferable {
    var id: UUID
    var shape: ObjShape
    var colorName: String
    var origin: DisplayID      // where it was generated (constant)
    var display: DisplayID     // where it currently sits
    var x: Double
    var y: Double
    var size: Double

    var position: CGPoint {
        get { CGPoint(x: x, y: y) }
        set { x = newValue.x; y = newValue.y }
    }

    var color: Color { Color.named(colorName) }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .demoObject)
    }
}

// MARK: - Color helper

extension Color {
    static func named(_ s: String) -> Color {
        switch s {
        case "green":  return .green
        case "orange": return .orange
        case "cyan":   return .cyan
        case "pink":   return .pink
        case "yellow": return .yellow
        case "purple": return .purple
        default:       return .white
        }
    }
}

// MARK: - Shared store

final class ObjectsStore: ObservableObject {
    static let shared = ObjectsStore()
    private init() {}

    @Published var objects: [DemoObject] = ObjectsStore.seed()
    /// Currently selected object (moved by the control-panel arrows).
    @Published var selectedID: UUID?

    func select(_ id: UUID?) { selectedID = id }

    /// Nudge the selected object by a delta (used by the arrow buttons).
    func nudgeSelected(dx: CGFloat, dy: CGFloat) {
        guard let id = selectedID,
              let i = objects.firstIndex(where: { $0.id == id }) else { return }
        objects[i].x += dx
        objects[i].y += dy
    }

    /// Resize the selected object by a delta (used by the +/- buttons).
    func resizeSelected(by delta: CGFloat) {
        guard let id = selectedID,
              let i = objects.firstIndex(where: { $0.id == id }) else { return }
        objects[i].size = max(30, min(220, objects[i].size + delta))
    }

    /// Move an object to a display at a given position (used on cross-window drop).
    func move(id: UUID, to display: DisplayID, at point: CGPoint) {
        guard let i = objects.firstIndex(where: { $0.id == id }) else { return }
        objects[i].display = display
        objects[i].position = point
    }

    /// Update only the position (used for live in-window mouse/finger dragging).
    func setPosition(id: UUID, _ point: CGPoint) {
        guard let i = objects.firstIndex(where: { $0.id == id }) else { return }
        objects[i].position = point
    }

    func objects(on display: DisplayID) -> [DemoObject] {
        objects.filter { $0.display == display }
    }

    private static func seed() -> [DemoObject] {
        [
            // Main objects — these also appear on the Extended display.
            DemoObject(id: UUID(), shape: .circle,   colorName: "green",  origin: .main,        display: .main,        x: 120, y: 160, size: 80),
            DemoObject(id: UUID(), shape: .square,   colorName: "orange", origin: .main,        display: .main,        x: 280, y: 130, size: 74),
            DemoObject(id: UUID(), shape: .triangle, colorName: "cyan",   origin: .main,        display: .main,        x: 200, y: 300, size: 90),
            // Interactive display — its own separate objects.
            DemoObject(id: UUID(), shape: .circle,   colorName: "purple", origin: .interactive, display: .interactive, x: 130, y: 150, size: 80),
            DemoObject(id: UUID(), shape: .square,   colorName: "yellow", origin: .interactive, display: .interactive, x: 260, y: 260, size: 74),
        ]
    }
}
