//
//  SessionStore.swift
//  VectraPro
//
//  Persists the auth Session to the Keychain.
//

import Foundation
import Security

enum SessionStore {

    private static let key = "com.vectrapro.session"

    /// Persists the session. Returns `false` (and logs in DEBUG) if encoding or
    /// the keychain write fails, so a lost session is observable rather than
    /// swallowed. Callers may ignore the result (the in-memory session is still
    /// valid for this launch — only persistence across launches is affected).
    @discardableResult
    static func save(_ session: Session) -> Bool {
        guard let data = try? JSONEncoder().encode(session) else {
            #if DEBUG
            print("SessionStore: failed to encode session — not persisted.")
            #endif
            return false
        }
        let status = Keychain.set(data, for: key)
        guard status == errSecSuccess else {
            #if DEBUG
            print("SessionStore: keychain write failed (OSStatus \(status)) — session not persisted.")
            #endif
            return false
        }
        return true
    }

    static func load() -> Session? {
        guard let data = Keychain.get(key) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    static func clear() {
        Keychain.delete(key)
    }
}
