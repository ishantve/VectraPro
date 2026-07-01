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
    @State private var isLandscape = false
    @State private var isWindowed = false
    @State private var activeLayers: Set<RadarLayer> = []
    /// Whether the layer buttons row is shown (toggled by the globe icon).
    @State private var showLayers = false

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

            if !presentation.isMapDetached {
                mapView
                    .ignoresSafeArea()
                    .id(providerRaw)   // recreate when the provider changes
            }

            controlPanel
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
            .padding(.leading, 16)
            // Drop below the native window controls only when windowed; keep the
            // original placement in fullscreen.
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
            leftToolbar
                .padding(.leading, 16)
        }
        // Obstacle & Zone lists open directly below their own button, left-aligned.
        .overlay(alignment: .topTrailing) {
            if showLayers, let layer = buttonAnchoredLayer {
                listPanel(for: layer)
                    .offset(x: buttonAnchoredPanelX(layer), y: layerRowBottom)
            }
        }
        .overlay(alignment: .bottomLeading) {
            zoomButtons
                .padding(.leading, 24)
                .padding(.bottom, 12)
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(alignment: .bottom, spacing: 16) {
                PushToTalkMicButton(viewModel: speechViewModel)
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
            .padding(.trailing, 16)
            .padding(.bottom, 12)
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
        .onDisappear { viewModel.stopSimulation() }
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

            Text("\(viewModel.enabledApproaches.count) enabled")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding()
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
        .padding()
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

    /// Left-side tool column: 4 tools + Instructor Mode (2). Clickable; actions TBD.
    private var leftToolbar: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 10) {
                toolButton("building.2.fill")                        // tower
                toolButton("antenna.radiowaves.left.and.right")      // radio
                toolButton("book.fill")                              // book
                toolButton("list.bullet.rectangle.portrait.fill")    // list
            }

            HStack(spacing: 6) {
                Image(systemName: "flag.fill")
                Text("Instructor Mode")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.9))

            VStack(spacing: 10) {
                toolButton("rectangle.stack.badge.plus")             // add layer
                toolButton("doc.text.fill")                          // document
            }
        }
    }

    private func toolButton(_ systemName: String) -> some View {
        Button {
            // TODO: wire tool action
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 48, height: 45)   // same as the top layer buttons
                .background(layerBG, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(layerBorder, lineWidth: 1))
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
            } else {
                openWindow(id: "radar")
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

#Preview {
    MapScreen()
}
