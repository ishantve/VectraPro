//
//  SessionCoordinator.swift
//  VectraPro
//
//  Starts and ends a recording around an exercise, and sweeps up after a crash.
//
//  The app half of the session lifecycle: ATCReplayKit owns the state machine and the storage, and this owns
//  *when* — which exercise, which owner, which seed, and where on this device it all lives.
//
//  ── Recording is optional, and that has to stay true ───────────────────────
//  Every method here can do nothing and the exercise is unaffected. `startRecording` returning nil is not an
//  error path, it is the normal state before anyone signs in or when recording is switched off. The gateway
//  behaves identically with no recorder attached, so there is no branch in the simulation for this.
//

import Foundation
import ATCReplayKit
import ATCReplayStore

@MainActor
final class SessionCoordinator {

    /// Where sessions live on this device.
    ///
    /// Application Support rather than Documents: these are the app's own records, not user documents to be
    /// browsed in Files, and they should not be offered up for iCloud backup by default — a trainee's whole
    /// session history is large and re-derivable in principle.
    nonisolated static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Sessions", isDirectory: true)
    }

    /// The app's coordinator.
    ///
    /// A singleton because sessions live in one place on disk and a second coordinator would open a second
    /// catalogue over the same directory. Created lazily so a test can build its own against a temporary root
    /// without this one ever touching Application Support.
    static let shared = SessionCoordinator()

    let sessions: SessionManager
    let branches: BranchManager

    /// The recorder for the session in progress, if any.
    private(set) var recorder: SessionRecorder?

    init(root: URL = SessionCoordinator.defaultRoot(),
         catalogue: SessionCatalogue? = nil,
         environment: RecordingEnvironment = .current(),
         retention: RetentionPolicy = .unlimited) {

        // An in-memory catalogue when SQLite will not open, rather than refusing to run. Losing the *index*
        // is recoverable — every session's manifest is still on disk — and an exercise should not be blocked
        // by a database problem.
        let resolved: SessionCatalogue
        if let catalogue {
            resolved = catalogue
        } else if let sqlite = try? SQLiteSessionCatalogue(
            url: root.appendingPathComponent("catalogue.sqlite")) {
            resolved = sqlite
        } else {
            resolved = InMemorySessionCatalogue()
        }

        sessions = SessionManager(root: root, catalogue: resolved,
                                  environment: environment, retention: retention)
        branches = BranchManager(sessions: sessions)
    }

    nonisolated deinit { }

    // MARK: - Starting

    /// Begins recording an exercise.
    ///
    /// Returns nil when recording could not start — the exercise proceeds either way, and the caller does not
    /// branch on this. The reason is logged rather than surfaced: a trainee starting an exercise does not need
    /// to hear about the recorder, and an assessment that failed to start is caught later by its session not
    /// existing.
    @discardableResult
    func startRecording(exercisePayload: Data,
                        exerciseID: String?,
                        exerciseName: String?,
                        seed: UInt64,
                        owner: OwnerID,
                        origin: SessionOrigin = .selfDirected) -> SessionRecorder? {

        stopRecording(tickCount: 0)   // a previous session must not stay open

        do {
            let session = try sessions.start(
                origin: origin, seed: seed, owner: owner,
                exercise: EmbeddedExercise(payload: exercisePayload,
                                           exerciseID: exerciseID,
                                           exerciseName: exerciseName),
                label: exerciseName ?? "")

            let manifest = try sessions.manifest(for: session.id)
            let recorder = SessionRecorder(
                sessionID: session.id,
                sessionClass: session.sessionClass,
                manifestBytes: try manifest.encoded(),
                store: EventStore(url: sessions.eventLogURL(for: session.id),
                                  sessionClass: session.sessionClass))
            try recorder.open()
            self.recorder = recorder
            return recorder
        } catch {
            log("could not start recording: \(error)")
            return nil
        }
    }

    // MARK: - Ending

    /// Ends the session in progress.
    ///
    /// A degraded recording is ended as degraded rather than completed, and an assessment that degraded is
    /// therefore never sealed — which is what stops an incomplete one passing for a finished one.
    func stopRecording(tickCount: Int) {
        guard let recorder, let active = sessions.active else { return }

        let seal = recorder.finish()
        self.recorder = nil

        do {
            if recorder.isDegraded {
                // Recorded as degraded, then ended. The machine allows `degraded → stopping → …`, and the
                // degradation outlives the teardown.
                let degraded = try active.degraded(reason: recorder.degradedReason ?? "unknown")
                try sessions.replaceActive(with: degraded)
            }
            try sessions.end(tickCount: tickCount, digest: seal)
        } catch {
            log("could not end session cleanly: \(error)")
            try? sessions.abandon(tickCount: tickCount)
        }
    }

    // MARK: - Branching

    /// Forks `parent` at `tick` and begins recording the branch.
    ///
    /// A branch is a **new** session: new id, new manifest, new log. The parent is marked superseded and
    /// otherwise untouched — its events after the fork point are kept, because comparing what the trainee did
    /// the first time against the second is the whole value of branching.
    ///
    /// ── The parent's inputs up to the fork are copied in ──────────────────────
    /// Without this a branch could not be replayed: its own log begins at the fork tick, and reaching that tick
    /// needs everything that happened before it. The architecture's answer was a state snapshot at the fork
    /// point; copying the *input prefix* does the same job for a fraction of the bytes — a few hundred events
    /// rather than a serialised world — and needs no snapshot machinery at all. Which is what recording causes
    /// rather than state buys: the prefix *is* the state, expressed smaller.
    ///
    /// The copies get the branch's own event ids, since an id is `(session, ordinal)`. That is right: they are
    /// this session's record of those instructions. An annotation on the parent still points at the parent.
    func branch(from parent: SessionID,
                at tick: Int,
                label: String = "") throws -> (session: ATCReplayKit.Session, recorder: SessionRecorder) {

        stopRecording(tickCount: tick)

        let child = try branches.fork(parent, at: tick, label: label)
        let manifest = try sessions.manifest(for: child.id)

        let store = EventStore(url: sessions.eventLogURL(for: child.id),
                               sessionClass: child.sessionClass)
        let recorder = SessionRecorder(sessionID: child.id,
                                      sessionClass: child.sessionClass,
                                      manifestBytes: try manifest.encoded(),
                                      store: store)
        try recorder.open()

        // The prefix, in order. Positions are preserved so the branch replays the parent's instructions at the
        // ticks they were issued; only the session they belong to has changed.
        for event in try sessions.events(for: parent) where event.tick < tick {
            recorder.record(event)
        }
        recorder.flush()

        self.recorder = recorder
        return (session: child, recorder: recorder)
    }

    // MARK: - Launch recovery

    /// Sweeps up sessions a dead process left open.
    ///
    /// Called once at launch. Truncates each log to its last valid frame and marks the session interrupted;
    /// an interrupted assessment is reported separately, because it is not a valid assessment and a UI must
    /// not present it as an ordinary recording.
    @discardableResult
    func recoverAfterLaunch() -> [SessionManager.RecoveryReport] {
        do {
            let reports = try sessions.recoverInterrupted()
            for report in reports where report.isIncompleteAssessment {
                log("assessment \(report.sessionID) was interrupted — not a valid assessment")
            }
            return reports
        } catch {
            log("recovery sweep failed: \(error)")
            return []
        }
    }

    private func log(_ message: String) {
        #if DEBUG
        print("[SessionCoordinator] \(message)")
        #endif
    }
}
