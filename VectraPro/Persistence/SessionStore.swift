//
//  SessionStore.swift
//  VectraPro
//
//  Persists the auth Session to the Keychain.
//

import Foundation

enum SessionStore {

    private static let key = "com.vectrapro.session"

    static func save(_ session: Session) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        Keychain.set(data, for: key)
    }

    static func load() -> Session? {
        guard let data = Keychain.get(key) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    static func clear() {
        Keychain.delete(key)
    }
}
