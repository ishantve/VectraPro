//
//  MapScreen.swift
//  VectraPro
//
//  Radar map screen with range rings, runways, and runway design controls.
//

import SwiftUI
import ATCReplayKit
import ATCSimKit

struct MapScreen: View {

    /// A recording to replay instead of flying.
    ///
    /// Passed in rather than chosen here: the browser lives on the exercise card, so by the time this screen opens
    /// the choice is already made. It also removes a hazard the radar-side entry point had — opening a replay
    /// mid-exercise detached the recorder and left the live session open, losing the run in progress.
    var replaying: SessionID?

    /// Open with the timeline panel already showing (the Logs action from the browser).
    var showTimeline: Bool = false

    @ObservedObject private var viewModel = MapViewModel.shared
    @ObservedObject private var speechViewModel = SpeechViewModel.shared
    @ObservedObject private var presentation = RadarPresentation.shared
    @ObservedObject private var feedbackManager = CommandFeedbackManager.shared
    @State private var isLandscape = false
    @State private var isWindowed = false
    @State private var activeLayers: Set<RadarLayer> = []
    /// Whether the layer buttons row is shown (toggled by the globe icon).
    @State private var showLayers = false
    /// Which left-toolbar menu is open (nil = none). Only one at a time.
    @State private var openLeftMenu: LeftMenu?
    // MARK: - Replay
    //
    // Replay drives the radar that is already on screen rather than opening a second one: a reviewer watches the
    // same picture the trainee flew, and the only thing added is a transport bar over it.

    /// The transport, present only while replaying. Its absence *is* "not replaying" — the screen keeps no
    /// separate flag, because a flag and a transport are two things that would have to agree.
    @State private var replay: ReplayTransport?

    /// Observed so the bar redraws as the replay advances. `ReplayClock` is the authority; this is a reference to
    /// it, not a copy of it.
    @StateObject private var replayClock = ReplayClock()

    /// Whether the replay timeline panel is visible over the replay.
    @State private var showTimelinePanel = false

    /// Which operations popup is open (nil = none). Only one at a time.
    enum OperationsPopup { case flightData }
    @State private var activePopup: OperationsPopup?
    /// Display-layer rows, in menu order (single source of truth).
    private let displayOptions = RadarDisplayLayer.allCases

    /// Tint applied to the layer icons (keeps their detail via colorMultiply).
    private let layerTint: Color = .white

    // Match the styling baked into the enroute/arrival/departure assets.
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(MapProvider.storageKey) private var providerRaw = MapProvider.mapLibre.rawValue

    private var provider: MapProvider { MapProvider(rawValue: providerRaw) ?? .mapLibre }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Always-black base so the navigation transition / map init never
            // flashes white before the map paints.
            Color.black.ignoresSafeArea()

            // Keep the map alive even while detached (just covered), so it
            // reappears instantly on close instead of re-initialising. While
            // detached, the blank main screen shows the big Macro Keyboard.
            mapView
                .ignoresSafeArea()
                .id(providerRaw)   // recreate when the provider changes
                // Kept alive while detached (covered by the workspace layout),
                // so it reappears instantly on close.

            controlPanel
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { updateLayout(for: proxy.size) }
                    .onChange(of: proxy.size) { _, size in updateLayout(for: size) }
            }
        }
        .overlay(alignment: .top) {
            if speechViewModel.showField {
                TranscriptionField(viewModel: speechViewModel)
                    .frame(maxWidth: 600)
                    .padding(.horizontal)
                    .padding(.top, isLandscape ? -12 : 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: speechViewModel.showField)
        .overlay(alignment: .topLeading) {
            exerciseHeader
                .padding(.leading, 16)
                .padding(.top, isWindowed ? 44 : 8)
        }
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 10) {
                // Always-visible top icons; the globe toggles the layer buttons.
                HStack(spacing: 12) {
                    windowToggleButton
                    topActionButton("flag.fill") { /* TODO */ }
                    topActionButton("person.2.fill") { /* TODO */ }
                    topActionButton("globe", isOn: showLayers) {
                        withAnimation(.easeInOut(duration: 0.2)) { showLayers.toggle() }
                    }
                }

                if showLayers {
                    layerButtons
                    // Holding + flight lists open here, right-aligned under the row.
                    if activeLayers.contains(.holdingPattern) {
                        let holdings = viewModel.holdingFixes
                        HoldingHangarPanel(
                            tabs: holdings.map { $0.fixName ?? "—" },
                            aircraftByHolding: holdings.map { fix in
                                viewModel.listAircraft.filter { $0.holdingName == fix.fixName }
                            }
                        )
                    } else if let category = activeFlightList {
                        HangarPanel(title: category.title,
                                    aircraft: viewModel.listAircraft.filter { $0.category == category.flightCategory })
                    }
                }
            }
            .padding(.trailing, 16)
            .padding(.top, 8)
        }
        .overlay(alignment: .leading) {
            leftToolbar.padding(.leading, 16)
        }
        // Left-tool menus: aligned with their button, capped + scrollable so they
        // never run off-screen or under the bottom controls.
        .overlay {
            if anyLeftMenuOpen {
                GeometryReader { geo in
                    let toolbarTop = max(8, (geo.size.height - toolbarHeight) / 2)
                    let menuTop = toolbarTop + activeMenuTopY
                    // Display (Map Layers) gets a bit more height; others keep clearance.
                    let bottomClearance: CGFloat = openLeftMenu == .display ? 70 : 100
                    let maxH = max(140, geo.size.height - menuTop - bottomClearance)
                    activeMenuView(maxHeight: maxH)
                        .offset(x: 68, y: menuTop)   // 16 pad + 48 button + 4 gap
                }
            }
        }
        // Obstacle & Zone lists open directly below their own button, left-aligned.
        .overlay(alignment: .topTrailing) {
            if showLayers, let layer = buttonAnchoredLayer {
                listPanel(for: layer)
                    .offset(x: buttonAnchoredPanelX(layer), y: layerRowBottom)
            }
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 12) {
                zoomButtons
                speedButtons
            }
            .padding(.leading, 24)
            // Lifts above the transport while replaying. Zoom stays reachable — looking closer at what happened
            // is most of what a review is — but it cannot sit under the bar.
            .padding(.bottom, replay == nil ? 12 : 96)
        }
        .overlay(alignment: .bottom) {
            if let replay {
                ReplayTransportBar(clock: replayClock, transport: replay) {
                    continueFromReplay(replay)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: replay == nil)
        // Reopen the timeline during a replay after it's been closed.
        .overlay(alignment: .bottomTrailing) {
            if replay != nil && !showTimelinePanel {
                Button { withAnimation(.easeInOut(duration: 0.2)) { showTimelinePanel = true } } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 18)).foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.72), in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 24).padding(.bottom, 96)
                .transition(.opacity)
            }
        }
        // The timeline panel over the replay; tapping a row seeks the live transport.
        .overlay {
            if showTimelinePanel, let replay, let sessionID = replaying {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showTimelinePanel = false } }
                    ReplayTimelineView(sessionID: sessionID,
                                       title: viewModel.exerciseName,
                                       transport: replay,
                                       clock: replayClock,
                                       onClose: { withAnimation(.easeInOut(duration: 0.2)) { showTimelinePanel = false } })
                }
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if replay == nil {
                feedbackLogView
                    .padding(.leading, 24)
                    .padding(.bottom, 90)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(alignment: .bottom, spacing: 16) {
                // Hidden while replaying, and not merely to clear the transport: a replay is driven by the
                // instructions that were recorded, so a live transmission has nowhere to go. Leaving the mic and
                // the keypad up would invite a reviewer to issue a command that silently does nothing. Continue
                // is how you take control, and hiding these is what makes that legible.
                if replay == nil {
                    PushToTalkMicButton(viewModel: speechViewModel)
                // Command keyboard only on the main (attached) view. While
                // detached, the big Macro Keyboard fills the main screen instead.
                if !presentation.isMapDetached {
                        CommandKeyboard(
                        onCommand: { CommandKeyboardHandler.shared.perform($0) },
                        requiresValue: { CommandKeyboardHandler.shared.requiresValue($0) },
                        promptFor: { CommandKeyboardHandler.shared.prompt(for: $0) },
                        onValue: { command, value in
                            CommandKeyboardHandler.shared.perform(command, value: value)
                        },
                        onBlock: { command, low, high in
                            CommandKeyboardHandler.shared.perform(command, low: low, high: high)
                        },
                        valueCount: { CommandKeyboardHandler.shared.valueCount(for: $0) },
                        onPreview: { text in speechViewModel.previewCommand(text) },
                        onDismissPreview: { _ in speechViewModel.clearPreview() }   // close at once on ENT/Back
                        )
                    }
                }
            }
            .padding(.trailing, 16)
            .padding(.bottom, 12)
        }
        // While the radar is in its own window, the main screen becomes a
        // three-panel workspace (left controls · right macro keyboard · bottom bar).
        .overlay {
            if presentation.isMapDetached {
                detachedLayout
            }
        }
        // Operations popups (e.g. Flight Data). Tapping anywhere outside closes.
        .overlay {
            if activePopup != nil {
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .onTapGesture { activePopup = nil }

                    if activePopup == .flightData {
                        GeometryReader { geo in
                            // Stick to the Operations button, like the left menus.
                            let toolbarTop = max(8, (geo.size.height - toolbarHeight) / 2)
                            FlightDataPopup(aircraft: selectedAircraft) { activePopup = nil }
                                .offset(x: 68, y: toolbarTop)   // 16 pad + 48 button + 4 gap
                        }
                    }
                }
            }
        }
        .overlay {
            if viewModel.isExerciseFinished {
                exerciseSummaryOverlay
            }
        }
        .navigationBarBackButtonHidden(true)
        .disablesSwipeBack()
        .focusable()
        .onKeyPress(.upArrow) { viewModel.pan(towardBearing: 0); return .handled }
        .onKeyPress(.downArrow) { viewModel.pan(towardBearing: 180); return .handled }
        .onKeyPress(.rightArrow) { viewModel.pan(towardBearing: 90); return .handled }
        .onKeyPress(.leftArrow) { viewModel.pan(towardBearing: 270); return .handled }
        .onKeyPress("=") { viewModel.zoom(by: 1); return .handled }   // "=" / "+"
        .onKeyPress("+") { viewModel.zoom(by: 1); return .handled }
        .onKeyPress("-") { viewModel.zoom(by: -1); return .handled }
        .onAppear {
            if let replaying {
                // No `reset()` first. Loading restores the world from the recording's own manifest, and resetting
                // would open a live recording session that the load then orphans.
                startReplay(of: replaying)
            } else {
                // A replay detaches recording (ReplayEngine.load sets radar.recording = nil so a replay
                // writes nothing). Re-attach it here for a live run, so an exercise started after viewing a
                // replay records again instead of silently not recording.
                if viewModel.recording == nil { viewModel.recording = .shared }
                viewModel.reset()   // fresh radar each time the screen opens
            }
            speechViewModel.prepare()
            let vm = viewModel
            speechViewModel.onCommand = { [weak vm] transcript in
                vm?.handleVoiceCommand(transcript)
            }
        }
        .onDisappear {
            // If we leave mid-replay (e.g. the back button rather than Continue), end the replay cleanly:
            // stops the engine's timer (otherwise it keeps firing on the shared radar) and hands recording
            // back to live. The Continue path tears down on its own.
            replay?.tearDown()
            viewModel.clearOnExit()
        }
    }

    /// Track orientation and whether we're in a windowed (non-fullscreen) scene —
    /// in Stage Manager the window doesn't fill the display, so the view is
    /// meaningfully smaller than the screen.
    private func updateLayout(for size: CGSize) {
        isLandscape = size.width > size.height
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) {
            let screen = scene.screen.bounds.size
            isWindowed = size.width < screen.width - 1 || size.height < screen.height - 1
        }
    }

    private var controlPanel: some View {
        VStack(spacing: 12) {
            approachChips
        }
        // Hug the runway chips instead of stretching the panel full width.
        .fixedSize(horizontal: true, vertical: false)
        .padding()
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
        // Sit above the zoom / fast-forward buttons at the bottom-left.
        .padding(.leading, 24)
        .padding(.bottom, 50)
    }

    // MARK: - Detached workspace layout (radar in its own window)

    /// Three-panel workspace shown on the main screen while the radar is
    /// detached: left controls · right macro keyboard · bottom control bar.
    private var detachedLayout: some View {
        let gap: CGFloat = 12
        return GeometryReader { geo in
            // Macro keyboard = 2/3 of the usable width, pinned to the right;
            // the left panel gets the remaining 1/3.
            let usable = geo.size.width - gap * 2 - gap   // minus outer + inner gap
            let macroW = max(0, usable * 2 / 3)

            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    // LEFT — takes the remaining width. Left-toolbar sits at the
                    // left-centre; the top-right action buttons at the top-right;
                    // any open menu / layer popup shows inside this panel.
                    workspacePanel {
                        ZStack(alignment: .topLeading) {
                            // Back button + timer — top-left of the panel.
                            exerciseHeader
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(10)

                            // Left toolbar — left edge, vertically centred.
                            leftToolbar
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                                .padding(.leading, 12)

                            // Open left-tool menu, next to the toolbar.
                            if anyLeftMenuOpen {
                                activeMenuView(maxHeight: 420)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                                    .padding(.leading, 70)
                            }

                            // Top-right action buttons + layer popup + hangar list.
                            VStack(alignment: .trailing, spacing: 10) {
                                HStack(spacing: 10) {
                                    windowToggleButton
                                    topActionButton("flag.fill") { /* TODO */ }
                                    topActionButton("person.2.fill") { /* TODO */ }
                                    topActionButton("globe", isOn: showLayers) {
                                        withAnimation(.easeInOut(duration: 0.2)) { showLayers.toggle() }
                                    }
                                }
                                if showLayers {
                                    layerButtons
                                    detachedHangarContent
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(10)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    // RIGHT — macro keyboard (2/3 of the width), pinned right.
                    // .equatable() so unrelated state changes don't rebuild it.
                    MacroKeyboard(onMacro: { _ in /* TODO: macro actions */ })
                        .equatable()
                        .frame(width: macroW)
                }

                // BOTTOM — zoom + fast-forward (left) and the mic (right).
                workspacePanel {
                    HStack(alignment: .center) {
                        HStack(spacing: 12) {
                            zoomButtons
                            speedButtons
                        }
                        Spacer()
                        PushToTalkMicButton(viewModel: speechViewModel)
                    }
                    .padding(.horizontal, 16)
                }
                .frame(height: 96)
            }
            .padding(gap)
        }
        .background(Color.black.ignoresSafeArea())
    }

    /// The hangar / list panel for the currently-selected layer, shown inside
    /// the detached left panel (holding, flight lists, obstacles, zones).
    @ViewBuilder
    private var detachedHangarContent: some View {
        if activeLayers.contains(.holdingPattern) {
            let holdings = viewModel.holdingFixes
            HoldingHangarPanel(
                tabs: holdings.map { $0.fixName ?? "—" },
                aircraftByHolding: holdings.map { fix in
                    viewModel.listAircraft.filter { $0.holdingName == fix.fixName }
                }
            )
        } else if let category = activeFlightList {
            HangarPanel(title: category.title,
                        aircraft: viewModel.listAircraft.filter { $0.category == category.flightCategory })
        } else if let layer = buttonAnchoredLayer {
            listPanel(for: layer)
        }
    }

    @ViewBuilder
    private func workspacePanel<Content: View>(
        @ViewBuilder _ content: @escaping () -> Content
    ) -> some View {
        WorkspacePanel(content: content)
    }

    @ViewBuilder
    private var mapView: some View {
        if provider == .google {
            GoogleRadarMapView(viewModel: viewModel)
        } else {
            // MapLibre-backed (OpenStreetMap or ArcGIS) — same renderer, different tiles.
            RadarMapView(viewModel: viewModel, styleURL: MapStyleProvider.styleURL(for: provider))
        }
    }

    /// Total height of the left toolbar (used to locate its centred position).
    private let toolbarHeight: CGFloat = 354   // 4 tools(210) + 12 + label(20) + 12 + 2 instr(100)

    private var anyLeftMenuOpen: Bool { openLeftMenu != nil }

    /// Toggle a left-toolbar menu (closes any other that was open).
    private func toggleLeftMenu(_ menu: LeftMenu) {
        withAnimation(.easeInOut(duration: 0.2)) {
            openLeftMenu = (openLeftMenu == menu) ? nil : menu
        }
    }

    /// Top Y (within the toolbar) of the button that opened the active menu,
    /// so the popup aligns with its icon. Metrics: button 45h, spacing 10,
    /// group spacing 12, label 20h.
    private var activeMenuTopY: CGFloat {
        switch openLeftMenu {
        case .operations: return 0                        // tower (1st tool)
        case .comms:     return 1 * 55                    // radio (2nd tool)
        case .reference: return 2 * 55                    // book (3rd tool)
        case .display:   return 3 * 55                    // list (4th tool)
        case .insert:    return 210 + 12 + 20 + 12        // add-layer (1st instructor)
        case .collab:    return 210 + 12 + 20 + 12 + 55   // doc (2nd instructor)
        case .none:      return 0
        }
    }

    /// Left-side tool column: 4 tools + Instructor Mode (2). Clickable; actions TBD.
    // MARK: - Replay actions

    /// Loads a recording and shows the transport over the radar.
    ///
    /// The engine is built with the screen's own clock, so the bar observes the same authority the engine writes —
    /// rather than the screen keeping a copy that would need syncing.
    private func startReplay(of sessionID: SessionID) {
        let engine = ReplayEngine(radar: viewModel, recording: .shared, clock: replayClock)
        do {
            try engine.load(sessionID)
            replay = ReplayTransport(engine: engine)
            showTimelinePanel = showTimeline   // Logs action opens straight into the timeline
        } catch {
            feedbackManager.commandError("Unable to open that recording")
            #if DEBUG
            print("[MapScreen] replay load failed: \(error)")
            #endif
        }
    }

    /// Forks here and hands the radar back to a live exercise.
    ///
    /// Dismissing the bar is all the screen has to do — the world is already live, because it was reached by
    /// simulating rather than by being restored.
    private func continueFromReplay(_ transport: ReplayTransport) {
        // Named for the point it left, because "Continued" on its own makes every branch of a session an
        // identical row in the browser — which is exactly what the snapshot pass showed.
        let from = replayClock.position
        let label = String(format: "Continued from %02d:%02d", from / 60, from % 60)
        guard transport.perform(.continueLive(label: label)) else {
            feedbackManager.commandError("Unable to continue from here")
            return
        }
        replay = nil
    }

    /// Back button and clock. Both layouts show it; each pads it differently.
    private var exerciseHeader: some View {
        ExerciseHeader(elapsedSeconds: viewModel.elapsedSeconds,
                       showsTimer: viewModel.exerciseDurationSeconds > 0) {
            dismiss()
        }
    }

    private var leftToolbar: some View {
        LeftToolbar(openMenu: openLeftMenu) { toggleLeftMenu($0) }
    }

    /// The currently-open left-tool menu, capped to `maxHeight` (scrolls if taller).
    @ViewBuilder
    private func activeMenuView(maxHeight: CGFloat) -> some View {
        switch openLeftMenu {
        case .operations:
            MenuCard(width: 230, maxHeight: maxHeight, title: "OPERATIONS", rows: 4) {
                MenuActionRow(systemName: "doc.text.fill", title: "Flight Data") {
                    openLeftMenu = nil            // close the menu
                    activePopup = .flightData     // open the popup
                }
                MenuDivider()
                MenuActionRow(systemName: "airplane", title: "Aircraft Control")
                MenuDivider()
                MenuActionRow(systemName: "arrow.left.arrow.right", title: "Handoffs")
                MenuDivider()
                MenuActionRow(systemName: "square.grid.2x2.fill", title: "Sector Management")
            }
        case .comms:
            MenuCard(width: 230, maxHeight: maxHeight, title: "COMMUNICATIONS", rows: 3) {
                MenuActionRow(systemName: "antenna.radiowaves.left.and.right", title: "Radio Operations")
                MenuDivider()
                MenuActionRow(systemName: "message.fill", title: "Message Center")
                MenuDivider()
                MenuActionRow(systemName: "mappin.and.ellipse", title: "Coordination")
            }
        case .reference:
            MenuCard(width: 230, maxHeight: maxHeight, title: "REFERENCE", rows: 3) {
                MenuActionRow(systemName: "map.fill", title: "Maps & Charts")
                MenuDivider()
                MenuActionRow(systemName: "gearshape.2.fill", title: "Procedures")
                MenuDivider()
                MenuActionRow(systemName: "doc.text.magnifyingglass", title: "Quick Reference")
            }
        case .display:
            MenuCard(width: 250, maxHeight: maxHeight, title: "MAP LAYERS", rows: displayOptions.count) {
                ForEach(displayOptions) { option in
                    LayerToggleRow(layer: option,
                                   isOn: viewModel.layerOn(option)) {
                        viewModel.setLayer(option, $0)
                    }
                    if option != displayOptions.last { MenuDivider() }
                }
            }
        case .insert:
            MenuCard(width: 240, maxHeight: maxHeight, title: "INSERT", rows: 9) {
                MenuToggleRow(systemName: "ruler", title: "Distance Measurement",
                              isOn: viewModel.isDistanceMeasuring) {
                    viewModel.toggleDistanceMeasurement()
                    if viewModel.isDistanceMeasuring { openLeftMenu = nil }
                }
                MenuDivider()
                MenuActionRow(systemName: "cloud.fill", title: "Insert Weather")
                MenuDivider()
                MenuActionRow(systemName: "exclamationmark.triangle.fill", title: "Insert NOTAM")
                MenuDivider()
                MenuActionRow(systemName: "airplane", title: "Insert Rogue Plane")
                MenuDivider()
                MenuActionRow(systemName: "flame.fill", title: "Engine Fire")
                MenuDivider()
                MenuActionRow(systemName: "fanblades.fill", title: "Single Engine Failure")
                MenuDivider()
                MenuActionRow(systemName: "gearshape.2.fill", title: "Double Engine Failure")
                MenuDivider()
                MenuActionRow(systemName: "wrench.and.screwdriver.fill", title: "Hydraulic Failure")
                MenuDivider()
                MenuActionRow(systemName: "cross.case.fill", title: "Medical Emergency")
            }
        case .collab:
            MenuCard(width: 220, maxHeight: maxHeight, title: "ATC COLLABORATION HUB", rows: 4) {
                MenuActionRow(systemName: "questionmark.circle", title: "Ask A Question")
                MenuDivider()
                MenuActionRow(systemName: "text.bubble", title: "Comment")
                MenuDivider()
                MenuActionRow(systemName: "airplane", title: "Issue TFR")
                MenuDivider()
                MenuActionRow(systemName: "list.bullet.rectangle", title: "Issue PREP")
            }
        case .none:
            EmptyView()
        }
    }

    /// The currently-selected aircraft (nil when none is selected → the Flight
    /// Data popup shows all fields blank/dashed).
    private var selectedAircraft: Aircraft? {
        guard let id = viewModel.selectedAircraftID else { return nil }
        return viewModel.listAircraft.first { $0.id == id }
    }

    /// Top-right action icon (flag / people / globe). `isOn` highlights it.
    private func topActionButton(_ systemName: String,
                                 isOn: Bool = false,
                                 action: @escaping () -> Void) -> some View {
        TopActionButton(systemName: systemName, isOn: isOn, action: action)
    }

    /// Open the radar in its own window, or merge it back into this screen.
    private var windowToggleButton: some View {
        Button {
            if presentation.isMapDetached {
                dismissWindow(id: "radar")
                presentation.isMapDetached = false
            } else {
                openWindow(id: "radar")
                presentation.isMapDetached = true
            }
        } label: {
            Image(systemName: presentation.isMapDetached ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.6), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 1))
        }
    }

    /// The active flight-list layer whose hangar panel is shown.
    private var activeFlightList: RadarLayer? {
        [.arrival, .departure, .enroute].first { activeLayers.contains($0) }
    }

    /// The active layer whose list opens under its own button (Obstacle / Zone).
    private var buttonAnchoredLayer: RadarLayer? {
        [.obstacle, .zone].first { activeLayers.contains($0) }
    }

    // Top-right button-row metrics (must match the rendered layout).
    private let layerBtnWidth: CGFloat = 48
    private let layerBtnSpacing: CGFloat = 8
    private let rowTrailingPadding: CGFloat = 16
    private let rowTopPadding: CGFloat = 8

    /// Y just below the layer button row (icon row + spacing + layer row + gap).
    private var layerRowBottom: CGFloat { rowTopPadding + 45 + 10 + 45 + 8 }

    private func panelWidth(_ layer: RadarLayer) -> CGFloat {
        switch layer {
        case .obstacle: return 210
        default:        return 180   // zone
        }
    }

    /// X offset (from the trailing edge) so the panel's left edge sits under the
    /// layer button's left edge. Negative moves left from the right edge.
    private func buttonAnchoredPanelX(_ layer: RadarLayer) -> CGFloat {
        guard let index = RadarLayer.allCases.firstIndex(of: layer) else { return 0 }
        let count = RadarLayer.allCases.count
        let step = layerBtnWidth + layerBtnSpacing
        // Distance from the screen's right edge to this button's left edge.
        let leftEdgeDistance = rowTrailingPadding
            + CGFloat(count - 1 - index) * step
            + layerBtnWidth
        return panelWidth(layer) - leftEdgeDistance
    }

    /// The list panel for the button-anchored layers (Obstacle / Zone).
    @ViewBuilder
    private func listPanel(for layer: RadarLayer) -> some View {
        switch layer {
        case .obstacle: ObstacleListPanel(obstacles: viewModel.obstructions)
        case .zone:     ZoneListPanel(zones: viewModel.zones)
        default:        EmptyView()
        }
    }

    /// Toggle a layer. Hangar layers (arrival/departure/enroute/holding) are
    /// single-select — opening one closes the others; the rest toggle freely.
    private func toggleLayer(_ layer: RadarLayer) {
        if activeLayers.contains(layer) {
            activeLayers.remove(layer)
        } else {
            // Hangar layers are single-select: opening one closes the others.
            if layer.opensHangar {
                for other in RadarLayer.allCases where other != layer && other.opensHangar {
                    activeLayers.remove(other)
                }
            }
            activeLayers.insert(layer)
        }
    }

    /// Obstacles / Enroute / Arrival / Departure layer toggles (40×40, asset art).
    private var layerButtons: some View {
        HStack(spacing: 8) {
            ForEach(RadarLayer.allCases) { layer in
                let on = activeLayers.contains(layer)
                Button {
                    toggleLayer(layer)
                } label: {
                    layerIcon(layer)
                        .frame(width: 48, height: 45)   // matches the baked assets
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.green, lineWidth: 2)
                            .opacity(on ? 1 : 0))   // selection highlight
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func layerIcon(_ layer: RadarLayer) -> some View {
        RadarLayerIcon(layer: layer, tint: layerTint)
    }

    // MARK: - Overlay controls
    //
    // Each of these lives in its own file now; what stays here is the wiring that
    // says where the values come from.

    private var feedbackLogView: some View {
        FeedbackLogView(feedbackManager: feedbackManager)
    }

    private var zoomButtons: some View {
        RadarZoomControl { viewModel.zoom(by: $0) }
    }

    private var speedButtons: some View {
        SimulationSpeedControl(
            speed: viewModel.simulationSpeed,
            canSlowDown: viewModel.simulationSpeed != MapViewModel.speedOptions.first,
            canSpeedUp: viewModel.simulationSpeed != MapViewModel.speedOptions.last,
            slowDown: { viewModel.decreaseSpeed() },
            speedUp: { viewModel.increaseSpeed() })
    }

    @ViewBuilder
    private var exerciseSummaryOverlay: some View {
        ExerciseSummaryOverlay(exerciseName: viewModel.exerciseName,
                               durationSeconds: viewModel.exerciseDurationSeconds) {
            viewModel.clearOnExit()
            dismiss()
        }
    }

    private var approachChips: some View {
        ApproachChips(approaches: viewModel.allApproaches,
                      isEnabled: { viewModel.isEnabled($0) },
                      toggle: { viewModel.toggleApproach($0) })
    }
}

#Preview {
    MapScreen()
}
