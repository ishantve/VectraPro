//
//  SessionManifest.swift
//  ATCReplayKit
//
//  Everything needed to reconstruct a session, other than its events.
//
//  Written once, at session start, and never mutated. Small, and deliberately human-readable on disk:
//  when a recording will not open, the first question is always "what seed and build was this?", and
//  that should be answerable with `cat`.
//
//  ── The exercise payload is embedded, not referenced ────────────────────────
//  The manifest carries the exercise configuration **as the bytes the backend actually served**. Not
//  an exercise id, not a URL. If a replay re-fetched its configuration and the backend had since
//  changed a fix, a runway or an airline, the replay would be of a *different world* — every aircraft
//  position subtly wrong, with no error anywhere. That is the kind of bug that destroys trust in a
//  replay system, so the payload is part of the recording.
//
//  It is stored as opaque `Data` plus a digest. This package does not decode it and does not want to:
//  the payload's shape belongs to the app, and keeping it opaque means the manifest cannot drift out
//  of step with it, and cannot re-encode it into something byte-different from what arrived.
//

import Foundation

// MARK: - Owner

/// Who recorded a session.
///
/// Both cases exist because a trainee may practise before signing in, and those sessions should not be
/// second-class or stored differently. Carrying the distinction — rather than inventing a fake user id
/// — is what lets a local session be adopted later if sign-in ever needs to claim it.
public enum OwnerID: Equatable, Hashable, Codable, Sendable {

    /// The authenticated backend user id. The only kind that can be shared or assessed.
    case user(String)

    /// A device-scoped identity for an unauthenticated trainee. Stable per install, meaningless
    /// elsewhere.
    case device(UUID)

    /// A single string form, for storage and for grouping a list by owner.
    ///
    /// Prefixed so the two spaces cannot collide: a backend id that happened to look like a UUID must
    /// not match a device identity.
    public var storageKey: String {
        switch self {
        case .user(let id):     return "user:\(id)"
        case .device(let uuid): return "device:\(uuid.uuidString)"
        }
    }

    public init?(storageKey: String) {
        if storageKey.hasPrefix("user:") {
            self = .user(String(storageKey.dropFirst(5)))
        } else if storageKey.hasPrefix("device:"),
                  let uuid = UUID(uuidString: String(storageKey.dropFirst(7))) {
            self = .device(uuid)
        } else {
            return nil
        }
    }

    /// Whether this owner can share a session or be assessed.
    ///
    /// A device identity cannot: there is nobody to attribute the result to, and an assessment needs
    /// someone to be about.
    public var isAuthenticated: Bool {
        if case .user = self { return true }
        return false
    }
}

// MARK: - Environment

/// What computed the recording.
///
/// Recorded because a replay is only faithful on a machine that computes the same way. The
/// architecture check found arm64 and x86_64 to agree, but that is a measurement of today's
/// toolchain, not a law — so the facts are stored and a mismatch can be reported rather than assumed
/// away.
public struct RecordingEnvironment: Equatable, Codable, Sendable {

    /// Format version of the manifest and event log. A session claiming a version this build does not
    /// know is refused rather than opened optimistically — half-reading a future format is how you
    /// corrupt it.
    public let schemaVersion: Int

    /// The app build that recorded it. A replay under a different build is legitimate for review and
    /// suspect for scoring, and the UI should be able to say which.
    public let buildVersion: String

    /// `"arm64"`, `"x86_64"`. Compared on replay.
    public let architecture: String

    /// `"iOS 26.3"`, `"macOS 26.5"` — the OS supplies `sin`/`cos`, so it is part of the answer to
    /// "would this compute the same".
    public let platform: String

    public static let currentSchemaVersion = 1

    public init(schemaVersion: Int = RecordingEnvironment.currentSchemaVersion,
                buildVersion: String,
                architecture: String = RecordingEnvironment.currentArchitecture,
                platform: String) {
        self.schemaVersion = schemaVersion
        self.buildVersion = buildVersion
        self.architecture = architecture
        self.platform = platform
    }

    public static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    /// Whether a replay here can be compared against a recording made in `other`.
    ///
    /// Only the architecture is required to match. The build may differ — that is ordinary, since a
    /// session outlives the version that recorded it — and the caller decides what a build difference
    /// means for scoring.
    public func canReproduce(_ other: RecordingEnvironment) -> Bool {
        schemaVersion == other.schemaVersion && architecture == other.architecture
    }
}

// MARK: - Exercise

/// The exercise configuration, exactly as served.
public struct EmbeddedExercise: Equatable, Codable, Sendable {

    /// The raw bytes. Opaque here on purpose — see the file header.
    public let payload: Data

    /// SHA-256 of `payload`, hex. Lets a replay prove it is using the same configuration without
    /// decoding it, and lets two sessions be recognised as sharing one exercise.
    public let digest: String

    /// The backend's own identifier, for display and for grouping. **Not** what the replay uses —
    /// that is `payload`.
    public let exerciseID: String?
    public let exerciseName: String?

    public init(payload: Data, exerciseID: String? = nil, exerciseName: String? = nil) {
        self.payload = payload
        self.digest = SHA256.hex(payload)
        self.exerciseID = exerciseID
        self.exerciseName = exerciseName
    }

    public var byteCount: Int { payload.count }
}

// MARK: - Manifest

/// A session's reconstruction data. Immutable once written.
public struct SessionManifest: Equatable, Codable, Sendable {

    public let sessionID: SessionID
    public let sessionClass: SessionClass

    /// How the session came about. Determines `sessionClass`; see `SessionOrigin`.
    public let origin: SessionOrigin

    /// The root of every random choice the run makes.
    public let seed: UInt64

    public let ownerID: OwnerID
    public let environment: RecordingEnvironment
    public let exercise: EmbeddedExercise

    /// When recording started. Wall-clock, for display and ordering only — never read by the
    /// simulation.
    public let createdAt: Date

    /// The assignment this session answers, when there is one.
    ///
    /// Optional and unpopulated for now, deliberately: the instructor workflow is not settled, and
    /// nothing in this phase should wait on it. The field exists so attaching one later is additive
    /// rather than a schema change — a recording made today can be recognised tomorrow as having had
    /// no assignment, which is different from the field not existing.
    public let assignmentID: AssignmentID?

    public init(sessionID: SessionID,
                origin: SessionOrigin,
                seed: UInt64,
                ownerID: OwnerID,
                environment: RecordingEnvironment,
                exercise: EmbeddedExercise,
                createdAt: Date,
                assignmentID: AssignmentID? = nil) {
        self.sessionID = sessionID
        self.origin = origin
        self.sessionClass = origin.sessionClass
        self.seed = seed
        self.ownerID = ownerID
        self.environment = environment
        self.exercise = exercise
        self.createdAt = createdAt
        // An assignment origin already names one; an explicit argument must not contradict it.
        self.assignmentID = assignmentID ?? origin.assignmentID
    }

    // MARK: Encoding

    /// Pretty-printed with sorted keys.
    ///
    /// Readable on purpose (see the header) and sorted so the bytes are stable — a seal is computed
    /// over them, and a digest that changed with dictionary order would be worthless.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> SessionManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(SessionManifest.self, from: data)
        guard manifest.environment.schemaVersion <= RecordingEnvironment.currentSchemaVersion else {
            throw ManifestError.futureSchema(manifest.environment.schemaVersion)
        }
        return manifest
    }

    /// Whether the embedded payload still matches its digest.
    ///
    /// Cheap, and worth doing before a replay: a corrupted payload would otherwise replay a
    /// subtly-wrong world rather than fail.
    public var payloadIsIntact: Bool {
        SHA256.hex(exercise.payload) == exercise.digest
    }
}

public enum ManifestError: Error, Equatable {
    /// Recorded by a newer build than this one. Refused rather than half-read.
    case futureSchema(Int)
    case unreadable(String)
    case payloadDigestMismatch
}

// MARK: - Origin coding

extension SessionOrigin: Codable {

    private enum CodingKeys: String, CodingKey {
        case kind, assignmentID, assignedBy, parentID, forkTick
    }

    private enum Kind: String, Codable {
        case selfDirected, assignment, fork
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .selfDirected:
            try container.encode(Kind.selfDirected, forKey: .kind)
        case .assignment(let id, let assignedBy):
            try container.encode(Kind.assignment, forKey: .kind)
            try container.encode(id, forKey: .assignmentID)
            try container.encode(assignedBy, forKey: .assignedBy)
        case .fork(let parent, let tick):
            try container.encode(Kind.fork, forKey: .kind)
            try container.encode(parent, forKey: .parentID)
            try container.encode(tick, forKey: .forkTick)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .selfDirected:
            self = .selfDirected
        case .assignment:
            self = .assignment(try container.decode(AssignmentID.self, forKey: .assignmentID),
                               assignedBy: try container.decode(String.self, forKey: .assignedBy))
        case .fork:
            self = .fork(from: try container.decode(SessionID.self, forKey: .parentID),
                         at: try container.decode(Int.self, forKey: .forkTick))
        }
    }

    /// The assignment named by this origin, if any.
    var assignmentID: AssignmentID? {
        if case .assignment(let id, _) = self { return id }
        return nil
    }
}
