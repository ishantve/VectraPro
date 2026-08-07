//
//  VoskTestView.swift
//  VectraPro
//
//  Standalone debug screen for exercising VoskSpeechKit in isolation — loads the
//  bundled Vosk model, streams the mic, and shows live partial + final transcripts
//  plus the engine/model versions. Not part of the normal app flow.
//
//  DEBUG-only: the whole file compiles out of Release builds, so this screen (and
//  its RootView launcher, also #if DEBUG) never ships. The real push-to-talk mic
//  uses Vosk independently via SpeechViewModel / VoskLiveRecognizer.
//

#if DEBUG
import Combine
import SwiftUI
import VoskSpeechKit

@MainActor
final class VoskTestModel: ObservableObject {
    @Published var info = "loading…"
    @Published var status = "idle"
    @Published var partial = ""
    @Published var finals: [String] = []
    @Published private(set) var running = false

    private var model: VoskSpeechModel?
    private var session: VoskSpeechSession?

    func load() {
        do {
            let model = try VoskSpeechModel.bundledLatest()
            self.model = model
            info = "\(model.info?.displayName ?? "model") · engine \(VoskEngine.version)"
            status = "model loaded"
        } catch {
            info = "no bundled model"
            status = "error: \(error)"
        }
    }

    func toggle() {
        if running { stop(); return }
        guard let model else { status = "no model loaded"; return }
        do {
            let session = try VoskSpeechSession(model: model)
            // The session delivers callbacks on the main queue.
            session.onPartial = { [weak self] t in MainActor.assumeIsolated { self?.partial = t.value } }
            session.onResult = { [weak self] t in
                MainActor.assumeIsolated {
                    if !t.value.isEmpty { self?.finals.append(t.value) }
                    self?.partial = ""
                }
            }
            session.onError = { [weak self] e in MainActor.assumeIsolated { self?.status = "error: \(e)" } }
            try session.start()
            self.session = session
            running = true
            status = "listening…"
        } catch {
            status = "start failed: \(error)"
        }
    }

    func stop() {
        session?.stop()
        session = nil
        running = false
        status = "stopped"
    }
}

struct VoskTestView: View {
    @StateObject private var model = VoskTestModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Vosk Speech Test").font(.title2.bold())
            Text(model.info).font(.footnote).foregroundStyle(.secondary)
            Text("Status: \(model.status)").font(.subheadline)

            HStack {
                Button(model.running ? "Stop" : "Start") { model.toggle() }
                    .buttonStyle(.borderedProminent)
                Button("Clear") { model.finals = []; model.partial = "" }
                    .buttonStyle(.bordered)
            }

            GroupBox("Partial") {
                Text(model.partial.isEmpty ? "—" : model.partial)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            }

            GroupBox("Final results (\(model.finals.count))") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(model.finals.enumerated()), id: \.offset) { _, line in
                            Text("• \(line)").frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            }

            Spacer()
        }
        .padding()
        .onAppear { model.load() }
        .onDisappear { model.stop() }
    }
}
#endif
