//
//  SQLiteSessionCatalogue.swift
//  ATCReplayStore
//
//  The session index, on SQLite.
//
//  ── Schema ─────────────────────────────────────────────────────────────────
//
//    sessions
//      id               TEXT PRIMARY KEY     session UUID
//      owner_key        TEXT NOT NULL        "user:<id>" | "device:<uuid>"
//      session_class    TEXT NOT NULL        "training" | "assessment"
//      state            TEXT NOT NULL        "recording" | "completed" | "sealed" |
//                                            "interrupted" | "superseded"
//      state_digest     TEXT                 seal, when state = "sealed"
//      superseded_by    TEXT                 child session id, when state = "superseded"
//      superseded_at    INTEGER              tick, when state = "superseded"
//      label            TEXT NOT NULL
//      parent_id        TEXT                 lineage
//      fork_tick        INTEGER
//      seed             TEXT NOT NULL        UInt64 as text — see below
//      tick_count       INTEGER NOT NULL
//      created_at       REAL NOT NULL        seconds since epoch
//      exercise_name    TEXT
//      exercise_digest  TEXT NOT NULL
//      assignment_id    TEXT
//      manifest_version   INTEGER NOT NULL
//      build_version    TEXT NOT NULL
//      architecture     TEXT NOT NULL
//      storage_origin   TEXT NOT NULL        "local" | "received"
//
//    indexes
//      sessions_owner    (owner_key, created_at DESC)   the trainee's own list
//      sessions_origin   (storage_origin, created_at DESC)   "Shared with me"
//      sessions_parent   (parent_id)                    branch tree
//
//  Two schema decisions worth explaining.
//
//  **`seed` is TEXT.** SQLite integers are signed 64-bit, and a seed is an unsigned 64-bit value, so
//  half the seed space would round-trip as a negative number. Storing the decimal string keeps every
//  seed exact, which matters because a seed that comes back wrong is a session that can never be
//  replayed.
//
//  **The state is three columns, not one.** `.sealed` carries a digest and `.superseded` carries a
//  child and a tick. Flattening them into an encoded string would make them unqueryable and would put
//  a parser in the storage layer.
//
//  ── Durability ─────────────────────────────────────────────────────────────
//  WAL, and `synchronous = FULL`. The catalogue is an index and rebuildable from the manifests in
//  principle, but a torn write here loses the *list* of what exists, which is a poor thing to have to
//  rebuild by scanning directories at launch.
//

import Foundation
import SQLite3
import ReplayCore

public final class SQLiteSessionCatalogue: SessionCatalogue {

    /// Bumped only when the table shape changes. Migrations are additive: new columns, never a
    /// changed meaning.
    static let manifestVersion = 1

    private var db: OpaquePointer?

    /// Opens (creating if needed) the catalogue at `url`.
    ///
    /// Pass `":memory:"` for a throwaway database — useful for tests that want the real SQL rather
    /// than the in-memory stand-in, which is how the two implementations are held to the same
    /// behaviour.
    public init(url: URL) throws {
        try open(path: url.path, createDirectory: true)
    }

    public init(inMemory: Bool) throws {
        precondition(inMemory)
        try open(path: ":memory:", createDirectory: false)
    }

    deinit {
        sqlite3_close(db)
    }

    private func open(path: String, createDirectory: Bool) throws {
        if createDirectory {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                withIntermediateDirectories: true)
        }
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw CatalogueError.storageFailure(lastMessage)
        }
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = FULL")
        try execute("PRAGMA foreign_keys = ON")
        try migrate()
    }

    // MARK: - Schema

    private func migrate() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS sessions (
                id              TEXT PRIMARY KEY NOT NULL,
                owner_key       TEXT NOT NULL,
                session_class   TEXT NOT NULL,
                state           TEXT NOT NULL,
                state_digest    TEXT,
                superseded_by   TEXT,
                superseded_at   INTEGER,
                label           TEXT NOT NULL DEFAULT '',
                parent_id       TEXT,
                fork_tick       INTEGER,
                seed            TEXT NOT NULL,
                tick_count      INTEGER NOT NULL DEFAULT 0,
                created_at      REAL NOT NULL,
                exercise_name   TEXT,
                exercise_digest TEXT NOT NULL,
                assignment_id   TEXT,
                manifest_version  INTEGER NOT NULL,
                build_version   TEXT NOT NULL,
                architecture    TEXT NOT NULL,
                storage_origin  TEXT NOT NULL DEFAULT 'local'
            )
            """)
        try execute("""
            CREATE INDEX IF NOT EXISTS sessions_owner
                ON sessions (owner_key, created_at DESC)
            """)
        try execute("""
            CREATE INDEX IF NOT EXISTS sessions_origin
                ON sessions (storage_origin, created_at DESC)
            """)
        try execute("CREATE INDEX IF NOT EXISTS sessions_parent ON sessions (parent_id)")
        try execute("PRAGMA user_version = \(Self.manifestVersion)")
    }

    // MARK: - SessionCatalogue

    public func upsert(_ summary: SessionSummary) throws {
        let sql = """
            INSERT INTO sessions (
                id, owner_key, session_class, state, state_digest, superseded_by, superseded_at,
                label, parent_id, fork_tick, seed, tick_count, created_at,
                exercise_name, exercise_digest, assignment_id,
                manifest_version, build_version, architecture, storage_origin
            ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20)
            ON CONFLICT(id) DO UPDATE SET
                state          = excluded.state,
                state_digest   = excluded.state_digest,
                superseded_by  = excluded.superseded_by,
                superseded_at  = excluded.superseded_at,
                label          = excluded.label,
                tick_count     = excluded.tick_count,
                storage_origin = excluded.storage_origin
            """
        // Only those seven columns are mutable, and the list is the point. What a session *is* — its
        // owner, class, seed, lineage, exercise and the environment that computed it — is settled when
        // recording starts. Letting an update touch any of it would let a later write rewrite which
        // world the session was recorded in, with nothing reporting it.
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        let state = Self.encode(summary.state)
        bind(statement, 1, summary.id.uuidString)
        bind(statement, 2, summary.ownerID.storageKey)
        bind(statement, 3, summary.sessionClass.rawValue)
        bind(statement, 4, state.name)
        bind(statement, 5, state.digest)
        bind(statement, 6, state.supersededBy)
        bind(statement, 7, state.supersededAt)
        bind(statement, 8, summary.label)
        bind(statement, 9, summary.parentID?.uuidString)
        bind(statement, 10, summary.forkTick)
        bind(statement, 11, String(summary.seed))          // unsigned: text, see the header
        bind(statement, 12, summary.tickCount)
        bind(statement, 13, summary.createdAt.timeIntervalSince1970)
        bind(statement, 14, summary.exerciseName)
        bind(statement, 15, summary.exerciseDigest)
        bind(statement, 16, summary.assignmentID?.uuidString)
        bind(statement, 17, summary.manifestVersion)
        bind(statement, 18, summary.buildVersion)
        bind(statement, 19, summary.architecture)
        bind(statement, 20, summary.origin.rawValue)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CatalogueError.storageFailure(lastMessage)
        }
    }

    public func summary(id: SessionID) throws -> SessionSummary? {
        try query("SELECT * FROM sessions WHERE id = ?1") { bind($0, 1, id.uuidString) }.first
    }

    public func remove(id: SessionID) throws {
        let statement = try prepare("DELETE FROM sessions WHERE id = ?1")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id.uuidString)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CatalogueError.storageFailure(lastMessage)
        }
    }

    public func sessions(ownedBy owner: OwnerID) throws -> [SessionSummary] {
        try query("""
            SELECT * FROM sessions
            WHERE owner_key = ?1 AND storage_origin = 'local'
            ORDER BY created_at DESC, id DESC
            """) { bind($0, 1, owner.storageKey) }
    }

    public func receivedSessions() throws -> [SessionSummary] {
        try query("""
            SELECT * FROM sessions WHERE storage_origin = 'received'
            ORDER BY created_at DESC, id DESC
            """)
    }

    public func allSessions() throws -> [SessionSummary] {
        try query("SELECT * FROM sessions ORDER BY created_at DESC, id DESC")
    }

    public func children(of parent: SessionID) throws -> [SessionSummary] {
        try query("""
            SELECT * FROM sessions WHERE parent_id = ?1 ORDER BY created_at DESC, id DESC
            """) { bind($0, 1, parent.uuidString) }
    }

    // MARK: - State encoding

    private static func encode(_ state: SessionState)
        -> (name: String, digest: String?, supersededBy: String?, supersededAt: Int?) {
        switch state {
        case .created:     return ("created", nil, nil, nil)
        case .recording:   return ("recording", nil, nil, nil)
        case .stopping:    return ("stopping", nil, nil, nil)
        case .completed:   return ("completed", nil, nil, nil)
        case .interrupted: return ("interrupted", nil, nil, nil)
        case .archived:    return ("archived", nil, nil, nil)
        // The reason rides in `state_digest`, which holds whichever string the state carries. One column
        // rather than one per state: they are mutually exclusive, and a column that is null for eight of
        // ten states is a column nobody can query usefully.
        case .sealed(let digest):   return ("sealed", digest, nil, nil)
        case .degraded(let reason): return ("degraded", reason, nil, nil)
        case .failed(let reason):   return ("failed", reason, nil, nil)
        case .superseded(let child, let tick):
            return ("superseded", nil, child.uuidString, tick)
        }
    }

    private static func decodeState(_ name: String,
                                   digest: String?,
                                   supersededBy: String?,
                                   supersededAt: Int?) -> SessionState {
        switch name {
        case "created":     return .created
        case "stopping":    return .stopping
        case "completed":   return .completed
        case "interrupted": return .interrupted
        case "archived":    return .archived
        case "sealed":      return .sealed(digest: digest ?? "")
        case "degraded":    return .degraded(reason: digest ?? "unknown")
        case "failed":      return .failed(reason: digest ?? "unknown")
        case "superseded":
            guard let supersededBy, let child = UUID(uuidString: supersededBy) else {
                // A superseded row that lost its child is corrupt. Reading it as interrupted is the
                // conservative answer: it is not scoreable and not presented as the active line.
                return .interrupted
            }
            return .superseded(by: child, at: supersededAt ?? 0)
        default:            return .recording
        }
    }

    // MARK: - Plumbing

    private var lastMessage: String {
        db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown sqlite error"
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw CatalogueError.storageFailure("\(lastMessage) — while running: \(sql)")
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CatalogueError.storageFailure("\(lastMessage) — while preparing: \(sql)")
        }
        return statement
    }

    private func query(_ sql: String,
                       bindings: (OpaquePointer?) -> Void = { _ in }) throws -> [SessionSummary] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bindings(statement)

        var rows: [SessionSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let row = Self.row(statement) { rows.append(row) }
        }
        return rows
    }

    /// Column order matches the `CREATE TABLE` above, and `SELECT *` relies on it.
    ///
    /// Fragile if a column is ever inserted in the middle — so the migration rule is *append only*,
    /// which is also what keeps old databases readable.
    private static func row(_ statement: OpaquePointer?) -> SessionSummary? {
        guard let idText = text(statement, 0), let id = UUID(uuidString: idText),
              let ownerKey = text(statement, 1), let owner = OwnerID(storageKey: ownerKey),
              let classText = text(statement, 2),
              let sessionClass = SessionClass(rawValue: classText),
              let stateName = text(statement, 3),
              let seedText = text(statement, 10), let seed = UInt64(seedText),
              let digestText = text(statement, 14),
              let buildVersion = text(statement, 17),
              let architecture = text(statement, 18),
              let originText = text(statement, 19),
              let origin = SessionSummary.StorageOrigin(rawValue: originText)
        else { return nil }

        return SessionSummary(
            id: id,
            ownerID: owner,
            sessionClass: sessionClass,
            state: decodeState(stateName,
                              digest: text(statement, 4),
                              supersededBy: text(statement, 5),
                              supersededAt: optionalInt(statement, 6)),
            label: text(statement, 7) ?? "",
            parentID: text(statement, 8).flatMap(UUID.init(uuidString:)),
            forkTick: optionalInt(statement, 9),
            seed: seed,
            tickCount: Int(sqlite3_column_int64(statement, 11)),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 12)),
            exerciseName: text(statement, 13),
            exerciseDigest: digestText,
            assignmentID: text(statement, 15).flatMap(UUID.init(uuidString:)),
            manifestVersion: Int(sqlite3_column_int64(statement, 16)),
            buildVersion: buildVersion,
            architecture: architecture,
            origin: origin)
    }

    private static func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private static func optionalInt(_ statement: OpaquePointer?, _ index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, index))
    }

    // SQLITE_TRANSIENT: sqlite copies the bytes, so a Swift String's storage need not outlive the
    // call. Passing STATIC here would be a use-after-free waiting for a release build.
    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        guard let value else { return sqlite3_bind_null(statement, index).discard() }
        sqlite3_bind_text(statement, index, value, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self)).discard()
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: Int?) {
        guard let value else { return sqlite3_bind_null(statement, index).discard() }
        sqlite3_bind_int64(statement, index, Int64(value)).discard()
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: Double) {
        sqlite3_bind_double(statement, index, value).discard()
    }
}

private extension Int32 {
    /// sqlite's bind functions return a status nobody checks individually — a bad bind shows up at
    /// `step`. Named so the discard is visibly deliberate rather than an oversight.
    func discard() {}
}
