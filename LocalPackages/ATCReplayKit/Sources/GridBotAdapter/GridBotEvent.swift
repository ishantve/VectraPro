//
//  GridBotEvent.swift
//  GridBotAdapter
//
//  How GridBot events are constructed — the only sanctioned way. Mirrors ATCEvent: one function per
//  recorded fact, named for the fact, building a core `Event` whose payload is this domain's body.
//

import Foundation
import ReplayCore

public enum GridBotEvent {

    public static func moved(steps: Int,
                             at position: EventPosition,
                             source: EventSource = .system) -> Event {
        Event(position: position, payload: GridBotPayload.moved(steps: steps).body, source: source)
    }

    public static func turned(_ direction: GridTurn,
                              at position: EventPosition,
                              source: EventSource = .system) -> Event {
        Event(position: position, payload: GridBotPayload.turned(direction).body, source: source)
    }

    public static func pickedUp(weight: Int = 1,
                                at position: EventPosition,
                                source: EventSource = .system) -> Event {
        Event(position: position, payload: GridBotPayload.pickedUp(weight: weight).body, source: source)
    }

    public static func annotated(note: String,
                                 at position: EventPosition,
                                 source: EventSource = .system) -> Event {
        Event(position: position, payload: GridBotPayload.annotated(note: note).body, source: source)
    }

    public static func timeline(_ action: TimelineAction,
                                at position: EventPosition,
                                source: EventSource = .system) -> Event {
        Event(position: position, payload: GridBotPayload.timeline(action).body, source: source)
    }

    /// What a recorded event says, in GridBot terms. Nil when the event carries another domain's payload.
    public static func payload(of event: Event) -> GridBotPayload? {
        try? event.payload.unwrap(GridBotPayload.self)
    }
}
