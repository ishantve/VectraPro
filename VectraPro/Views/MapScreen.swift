//
//  MapScreen.swift
//  VectraPro
//
//  Radar map screen with range rings, runways, and runway design controls.
//

import SwiftUI

struct MapScreen: View {

    @StateObject private var viewModel = MapViewModel()
    @StateObject private var speechViewModel = SpeechViewModel()
    @State private var isLandscape = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .bottom) {
            if viewModel.externalDisplay.isActive {
                // Map is on the external display; iPad keeps the controls.
                Color.black.ignoresSafeArea()
            } else {
                RadarMapView(controller: viewModel.mapController)
                    .ignoresSafeArea()
            }

            controlPanel
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { isLandscape = proxy.size.width > proxy.size.height }
                    .onChange(of: proxy.size) { _, size in isLandscape = size.width > size.height }
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
            .padding(.top, 8)
        }
        .overlay(alignment: .bottomTrailing) {
            VStack(alignment: .trailing, spacing: 16) {
                PushToTalkMicButton(viewModel: speechViewModel)
                zoomButtons
            }
            .padding(.trailing, 24)
            .padding(.bottom, 12)
        }
        .navigationBarBackButtonHidden(true)
        .disablesSwipeBack()
        .onAppear {
            viewModel.startSimulation()
            speechViewModel.prepare()
            let vm = viewModel
            speechViewModel.onCommand = { [weak vm] transcript in
                vm?.handleVoiceCommand(transcript)
            }
        }
        .onDisappear { viewModel.stopSimulation() }
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
