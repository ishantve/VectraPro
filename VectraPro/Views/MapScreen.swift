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

    var body: some View {
        ZStack(alignment: .bottom) {
            GoogleMapView(viewModel: viewModel)
                .ignoresSafeArea()

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
        .overlay(alignment: .bottomTrailing) {
            PushToTalkMicButton(viewModel: speechViewModel)
                .padding(24)
        }
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
