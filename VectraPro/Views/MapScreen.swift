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

    /// Tint applied to the layer icons (keeps their detail via colorMultiply).
    private let layerTint: Color = .white

    /// Top-right radar layer toggles — each uses its own image asset.
    enum RadarLayer: String, CaseIterable, Identifiable {
        case obstacle, zone, holdingPattern, enroute, arrival, departure
        var id: String { rawValue }
        var asset: String { rawValue }
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
            HStack(spacing: 12) {
                layerButtons
                windowToggleButton
            }
            .padding(.trailing, 16)
            .padding(.top, 8)
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

    /// Obstacles / Enroute / Arrival / Departure layer toggles (40×40, asset art).
    private var layerButtons: some View {
        HStack(spacing: 8) {
            ForEach(RadarLayer.allCases) { layer in
                let on = activeLayers.contains(layer)
                Button {
                    if on { activeLayers.remove(layer) } else { activeLayers.insert(layer) }
                    RadarLayerHandler.shared.toggle(layer, isOn: activeLayers.contains(layer))
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
