//
//  MapScreen.swift
//  VectraPro
//
//  Radar map screen with range rings, runways, and runway design controls.
//

import SwiftUI

struct MapScreen: View {

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
    enum LeftMenu { case operations, comms, reference, display, insert, collab }
    @State private var openLeftMenu: LeftMenu?
    /// Display-layer rows (icon, name), in order.
    private let displayOptions: [(icon: String, name: String)] = [
        ("cloud.fill", "Weather"),
        ("scope", "Radials"),
        ("scope", "Radials Names"),
        ("triangle.fill", "Fixes"),
        ("triangle.fill", "Fixes Names"),
        ("exclamationmark.triangle.fill", "NOTAM"),
        ("nosign", "Zone"),
        ("smallcircle.filled.circle", "Holding"),
        ("oval", "Holding racetrack"),
        ("point.3.connected.trianglepath.dotted", "Trail"),
        ("mountain.2.fill", "Obstacles"),
        ("wind", "Wind"),
        ("wind", "Wind Speed"),
        ("cloud.fill", "Clouds"),
        ("bolt.fill", "Lightening"),
        ("cloud.bolt.rain.fill", "Thunderstorm")
    ]

    /// Tint applied to the layer icons (keeps their detail via colorMultiply).
    private let layerTint: Color = .white

    /// Top-right radar layer toggles — each uses its own image asset.
    enum RadarLayer: String, CaseIterable, Identifiable {
        case obstacle, zone, holdingPattern, enroute, arrival, departure
        var id: String { rawValue }
        var asset: String { rawValue }

        /// Title shown above the hangar list.
        var title: String {
            switch self {
            case .arrival:   return "Arrival"
            case .departure: return "Departure"
            case .enroute:   return "Enroute"
            default:         return rawValue.capitalized
            }
        }

        /// The aircraft category this layer lists (nil = not a flight list).
        var flightCategory: FlightCategory? {
            switch self {
            case .arrival:   return .arrival
            case .departure: return .departure
            case .enroute:   return .enroute
            default:         return nil
            }
        }

        /// Layers that open a list panel (single-select among themselves).
        var opensHangar: Bool {
            flightCategory != nil || self == .holdingPattern || self == .zone || self == .obstacle
        }
        /// Enroute / Arrival / Departure ship with the grey bg + border baked into
        /// the asset; the first three are plain icons we style to match in code.
        var hasBakedStyle: Bool {
            switch self {
            case .enroute, .arrival, .departure: return true
            default: return false
            }
        }
    }

    // Match the styling baked into the enroute/arrival/departure assets.
    private let layerBG = Color(red: 0/255, green: 36/255, blue: 68/255).opacity(0.5)   // #002444
    private let layerBorder = Color(red: 110/255, green: 220/255, blue: 255/255)         // #6EDCFF
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
            // reappears instantly on close instead of re-initialising.
            mapView
                .ignoresSafeArea()
                .id(providerRaw)   // recreate when the provider changes
                .overlay {
                    if presentation.isMapDetached {
                        Color.black.ignoresSafeArea()
                    }
                }

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
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.6), in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 1))
                }

                if viewModel.exerciseDurationSeconds > 0 {
                    HStack(spacing: 6) {
                        Image("timer_icon")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                        Text(viewModel.elapsedSeconds.asTimerString)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    }
                    .foregroundStyle(Color(red: 0.2, green: 1.0, blue: 0.4))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.6), in: Capsule())
                    .overlay(Capsule().stroke(Color(red: 0.2, green: 1.0, blue: 0.4).opacity(0.4), lineWidth: 1))
                }
            }
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
            .padding(.bottom, 12)
        }
        .overlay(alignment: .bottomLeading) {
            feedbackLogView
                .padding(.leading, 24)
                .padding(.bottom, 90)
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(alignment: .bottom, spacing: 16) {
                PushToTalkMicButton(viewModel: speechViewModel)
                if presentation.isMapDetached {
                    // Radar is in its own window → show the Macro Keyboard here.
                    MacroKeyboard(
                        onMacro: { _ in /* TODO: macro actions */ }
                    )
                } else {
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
            .padding(.trailing, 16)
            .padding(.bottom, 12)
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
            viewModel.reset()   // fresh radar each time the screen opens
            speechViewModel.prepare()
            let vm = viewModel
            speechViewModel.onCommand = { [weak vm] transcript in
                vm?.handleVoiceCommand(transcript)
            }
        }
        .onDisappear { viewModel.clearOnExit() }
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
    private var leftToolbar: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 10) {
                toolButton("building.2.fill", isOn: openLeftMenu == .operations) {
                    toggleLeftMenu(.operations)                      // Operations
                }
                toolButton("antenna.radiowaves.left.and.right", isOn: openLeftMenu == .comms) {
                    toggleLeftMenu(.comms)                           // Communications
                }
                toolButton("book.fill", isOn: openLeftMenu == .reference) {
                    toggleLeftMenu(.reference)                       // Reference
                }
                toolButton("list.bullet.rectangle.portrait.fill", isOn: openLeftMenu == .display) {
                    toggleLeftMenu(.display)                         // Display layers
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "flag.fill")
                Text("Instructor Mode")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.9))
            .fixedSize()
            // Keep the column as wide as the buttons (48) with a fixed height so
            // button positions are deterministic; let the label overflow right.
            .frame(width: 48, height: 20, alignment: .leading)

            VStack(spacing: 10) {
                toolButton("rectangle.stack.badge.plus", isOn: openLeftMenu == .insert) {
                    toggleLeftMenu(.insert)                          // Insert
                }
                toolButton("doc.text.fill", isOn: openLeftMenu == .collab) {
                    toggleLeftMenu(.collab)                          // ATC Collaboration Hub
                }
            }
        }
    }

    private func toolButton(_ systemName: String, isOn: Bool = false, action: @escaping () -> Void = {}) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 48, height: 45)   // same as the top layer buttons
                .background(isOn ? Color(red: 0.20, green: 0.45, blue: 0.95) : layerBG,
                            in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(layerBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// The currently-open left-tool menu, capped to `maxHeight` (scrolls if taller).
    @ViewBuilder
    private func activeMenuView(maxHeight: CGFloat) -> some View {
        switch openLeftMenu {
        case .operations:
            menuCard(width: 230, maxHeight: maxHeight, title: "OPERATIONS", rows: 4) {
                collabRow("doc.text.fill", "Flight Data")
                Divider().overlay(.white.opacity(0.12))
                collabRow("airplane", "Aircraft Control")
                Divider().overlay(.white.opacity(0.12))
                collabRow("arrow.left.arrow.right", "Handoffs")
                Divider().overlay(.white.opacity(0.12))
                collabRow("square.grid.2x2.fill", "Sector Management")
            }
        case .comms:
            menuCard(width: 230, maxHeight: maxHeight, title: "COMMUNICATIONS", rows: 3) {
                collabRow("antenna.radiowaves.left.and.right", "Radio Operations")
                Divider().overlay(.white.opacity(0.12))
                collabRow("message.fill", "Message Center")
                Divider().overlay(.white.opacity(0.12))
                collabRow("mappin.and.ellipse", "Coordination")
            }
        case .reference:
            menuCard(width: 230, maxHeight: maxHeight, title: "REFERENCE", rows: 3) {
                collabRow("map.fill", "Maps & Charts")
                Divider().overlay(.white.opacity(0.12))
                collabRow("gearshape.2.fill", "Procedures")
                Divider().overlay(.white.opacity(0.12))
                collabRow("doc.text.magnifyingglass", "Quick Reference")
            }
        case .display:
            menuCard(width: 250, maxHeight: maxHeight, title: "MAP LAYERS", rows: displayOptions.count) {
                ForEach(displayOptions, id: \.name) { option in
                    displayRow(option.icon, option.name)
                    if option.name != displayOptions.last?.name {
                        Divider().overlay(.white.opacity(0.12))
                    }
                }
            }
        case .insert:
            menuCard(width: 240, maxHeight: maxHeight, title: "INSERT", rows: 9) {
                insertToggleRow("ruler", "Distance Measurement",
                                isOn: viewModel.isDistanceMeasuring) {
                    viewModel.toggleDistanceMeasurement()
                    if viewModel.isDistanceMeasuring { openLeftMenu = nil }
                }
                Divider().overlay(.white.opacity(0.12))
                collabRow("cloud.fill", "Insert Weather")
                Divider().overlay(.white.opacity(0.12))
                collabRow("exclamationmark.triangle.fill", "Insert NOTAM")
                Divider().overlay(.white.opacity(0.12))
                collabRow("airplane", "Insert Rogue Plane")
                Divider().overlay(.white.opacity(0.12))
                collabRow("flame.fill", "Engine Fire")
                Divider().overlay(.white.opacity(0.12))
                collabRow("fanblades.fill", "Single Engine Failure")
                Divider().overlay(.white.opacity(0.12))
                collabRow("gearshape.2.fill", "Double Engine Failure")
                Divider().overlay(.white.opacity(0.12))
                collabRow("wrench.and.screwdriver.fill", "Hydraulic Failure")
                Divider().overlay(.white.opacity(0.12))
                collabRow("cross.case.fill", "Medical Emergency")
            }
        case .collab:
            menuCard(width: 220, maxHeight: maxHeight, title: "ATC COLLABORATION HUB", rows: 4) {
                collabRow("questionmark.circle", "Ask A Question")
                Divider().overlay(.white.opacity(0.12))
                collabRow("text.bubble", "Comment")
                Divider().overlay(.white.opacity(0.12))
                collabRow("airplane", "Issue TFR")
                Divider().overlay(.white.opacity(0.12))
                collabRow("list.bullet.rectangle", "Issue PREP")
            }
        case .none:
            EmptyView()
        }
    }

    /// A styled popup card sized to its rows, capped at `maxHeight` (scrolls if
    /// taller). Height is computed from `rows` so it hugs content reliably.
    private func menuCard<Content: View>(width: CGFloat, maxHeight: CGFloat,
                                         title: String?, rows: Int,
                                         @ViewBuilder content: () -> Content) -> some View {
        let rowHeight: CGFloat = 48
        let titleHeight: CGFloat = title != nil ? 50 : 0
        let rowsHeight = 12 + CGFloat(rows) * rowHeight
        // The header stays fixed; only the rows scroll, capped to fit maxHeight.
        let scrollHeight = min(rowsHeight, max(80, maxHeight - titleHeight))

        return VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) { content() }
                    .padding(.vertical, 6)
            }
            .frame(height: scrollHeight)
        }
        .frame(width: width)
        .background(Color(red: 0.06, green: 0.10, blue: 0.18).opacity(0.97),
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(Color(red: 0.32, green: 0.56, blue: 0.95).opacity(0.7), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
    }

    private func displayRow(_ icon: String, _ name: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(.white)
                .frame(width: 26)
            Text(name)
                .font(.system(size: 16))
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { viewModel.layers[name] ?? false },
                set: { viewModel.setLayer(name, $0) }
            ))
            .labelsHidden()
            .tint(Color(red: 0.20, green: 0.55, blue: 0.98))
            .scaleEffect(0.8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func insertToggleRow(_ systemName: String, _ title: String,
                                  isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemName)
                    .font(.system(size: 18))
                    .foregroundStyle(isOn ? Color.orange : .white)
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(isOn ? Color.orange : .white)
                Spacer(minLength: 0)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isOn ? Color.orange : .white.opacity(0.4))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func collabRow(_ systemName: String, _ title: String) -> some View {
        Button {
            // TODO: wire hub action
        } label: {
            HStack(spacing: 14) {
                Image(systemName: systemName)
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Top-right action icon (flag / people / globe). `isOn` highlights it.
    private func topActionButton(_ systemName: String, isOn: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 48, height: 45)
                .background(layerBG, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(isOn ? Color.green : layerBorder, lineWidth: isOn ? 2 : 1))
        }
        .buttonStyle(.plain)
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
            if layer.opensHangar {
                for other in RadarLayer.allCases where other != layer && other.opensHangar {
                    if activeLayers.remove(other) != nil {
                        RadarLayerHandler.shared.toggle(other, isOn: false)
                    }
                }
            }
            activeLayers.insert(layer)
        }
        RadarLayerHandler.shared.toggle(layer, isOn: activeLayers.contains(layer))
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
        if layer.hasBakedStyle {
            // Grey background + cyan border already part of the asset.
            Image(layer.asset)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
        } else {
            // Plain icon — match the baked assets: small glyph, grey bg, cyan border.
            Image(layer.asset)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .colorMultiply(layerTint)
                // holdingPattern is a wide glyph — less padding so its height matches the rest.
                .padding(layer == .holdingPattern ? 8 : 13)
                .frame(width: 48, height: 45)
                .background(layerBG, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(layerBorder, lineWidth: 1))
        }
    }

    // MARK: - Voice feedback log

    private var feedbackLogView: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(feedbackManager.feedbackLog) { entry in
                HStack(spacing: 6) {
                    Image(systemName: entry.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(entry.isError
                            ? Color(red: 1.0, green: 0.35, blue: 0.35)
                            : Color(red: 0.2, green: 1.0, blue: 0.4))
                    Text(entry.text)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(
                            entry.isError
                                ? Color(red: 1.0, green: 0.35, blue: 0.35).opacity(0.4)
                                : Color(red: 0.2, green: 1.0, blue: 0.4).opacity(0.3),
                            lineWidth: 1
                        )
                )
            }
        }
        .frame(maxWidth: 280, alignment: .leading)
        .animation(.easeInOut(duration: 0.25), value: feedbackManager.feedbackLog.map(\.id))
    }

    private var zoomButtons: some View {
        HStack(spacing: 1) {
            zoomButton(systemImage: "minus", delta: -1)
            Divider().frame(height: 44).background(.white.opacity(0.2))
            zoomButton(systemImage: "plus", delta: 1)
        }
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.15), lineWidth: 1))
    }

    private func zoomButton(systemImage: String, delta: Double) -> some View {
        Button {
            viewModel.zoom(by: delta)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
        }
    }

    // MARK: - Simulation speed (fast-forward)

    private var speedButtons: some View {
        HStack(spacing: 1) {
            speedButton(systemImage: "backward.fill",
                        enabled: viewModel.simulationSpeed != MapViewModel.speedOptions.first) {
                viewModel.decreaseSpeed()
            }
            Divider().frame(height: 44).background(.white.opacity(0.2))
            Text("\(viewModel.simulationSpeed)X")
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(red: 0.2, green: 1.0, blue: 0.4))
                .frame(width: 52, height: 44)
            Divider().frame(height: 44).background(.white.opacity(0.2))
            speedButton(systemImage: "forward.fill",
                        enabled: viewModel.simulationSpeed != MapViewModel.speedOptions.last) {
                viewModel.increaseSpeed()
            }
        }
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.15), lineWidth: 1))
    }

    private func speedButton(systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(enabled ? .white : .white.opacity(0.3))
                .frame(width: 44, height: 44)
        }
        .disabled(!enabled)
    }

    @ViewBuilder
    private var exerciseSummaryOverlay: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()

            VStack(spacing: 24) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Color(red: 0.2, green: 1.0, blue: 0.4))

                Text("Exercise Complete")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)

                VStack(spacing: 8) {
                    Text(viewModel.exerciseName)
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.85))

                    Text("Duration: \(viewModel.exerciseDurationSeconds.asTimerString)")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                }

                Button {
                    viewModel.clearOnExit()
                    dismiss()
                } label: {
                    Text("Exit")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(width: 160, height: 44)
                        .background(Color(red: 0.2, green: 1.0, blue: 0.4), in: Capsule())
                }
            }
            .padding(40)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.12), lineWidth: 1))
            .padding(32)
        }
    }

    private var approachChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.allApproaches) { approach in
                    let on = viewModel.isEnabled(approach.id)
                    Button(approach.designator) {
                        viewModel.toggleApproach(approach.id)
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(on ? Color.green : Color.white.opacity(0.15), in: Capsule())
                    .foregroundStyle(on ? .black : .white)
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

private extension Int {
    /// Formats seconds as "HH:MM:SS".
    var asTimerString: String {
        let h = self / 3600
        let m = (self % 3600) / 60
        let s = self % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

#Preview {
    MapScreen()
}
