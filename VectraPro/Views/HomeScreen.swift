//
//  HomeScreen.swift
//  VectraPro
//
//  Root screen listing the available exercises as horizontal cards.
//

import SwiftUI
import ATCReplayKit

/// A chosen recording, on its way to the radar.
///
/// A wrapper because `navigationDestination(item:)` needs `Identifiable` and `SessionID` belongs to
/// ATCReplayKit — conforming it from here would be a retroactive conformance on someone else's type.
private struct PendingReplay: Identifiable, Hashable {
    let id = UUID()
    let sessionID: SessionID
}

struct HomeScreen: View {

    enum SimMode: String { case single, instructor }

    var onLogout: () -> Void = {}

    @StateObject private var viewModel = HomeViewModel()
    @ObservedObject private var auth = AuthService.shared
    @AppStorage(MapProvider.storageKey) private var providerRaw = MapProvider.mapLibre.rawValue
    @State private var startedExercise: Exercise?

    /// The exercise whose recordings are being browsed, if any.
    @State private var browsing: Exercise?

    /// A recording chosen for replay. Wrapped because navigation needs an `Identifiable`, and a `SessionID` is a
    /// value the package owns — conforming it here would be a retroactive conformance on someone else's type.
    @State private var replaying: PendingReplay?
    @State private var startError: String?
    @State private var showAccount = false
    @State private var mode: SimMode = .single

    private var provider: Binding<MapProvider> {
        Binding(
            get: { MapProvider(rawValue: providerRaw) ?? .mapLibre },
            set: { providerRaw = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {

                mapProviderPicker

                exerciseList
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                Image("MainMenu")
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
            }
            .navigationTitle("VectraPro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    accountMenu
                }
            }
            .navigationDestination(item: $startedExercise) { _ in
                MapScreen()
            }
            .navigationDestination(item: $replaying) { pending in
                MapScreen(replaying: pending.sessionID)
            }
            .sheet(item: $browsing) { exercise in
                ReplayBrowserView(coordinator: .shared,
                                  exerciseName: exercise.exerciseName) { sessionID in
                    replaying = PendingReplay(sessionID: sessionID)
                }
            }
            .task { await viewModel.load() }
            .alert("Couldn't start exercise", isPresented: .constant(startError != nil)) {
                Button("OK", role: .cancel) { startError = nil }
            } message: {
                Text(startError ?? "")
            }
        }
        .overlay(alignment: .topTrailing) { accountOverlay }
    }

    /// Asks the view model to load the exercise config + set up the radar, then
    /// navigates to it. The orchestration lives in the view model.
    private func start(_ exercise: Exercise) async {
        do {
            try await viewModel.startExercise(exercise)
            startedExercise = exercise
        } catch {
            startError = error.localizedDescription
        }
    }

    private var accountName: String {
        auth.nickname ?? auth.username ?? "Account"
    }

    private var accountMenu: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                showAccount.toggle()
            }
        } label: {
            Image("account")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 40, height: 40)
                .foregroundStyle(.white)
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "Ver \(v)"
    }

    // Dimmed backdrop + the popup card, anchored under the account icon.
    @ViewBuilder
    private var accountOverlay: some View {
        if showAccount {
            ZStack(alignment: .topTrailing) {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { dismissAccount() }

                accountPopup
                    .padding(.top, 52)
                    .padding(.trailing, 12)
                    .transition(.scale(scale: 0.9, anchor: .topTrailing).combined(with: .opacity))
            }
        }
    }

    private var accountPopup: some View {
        VStack(alignment: .leading, spacing: 18) {

            // Header — account icon + name
            HStack(spacing: 14) {
                Image("account")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 34, height: 34)
                    .foregroundStyle(.white)
                Text(accountName)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
            }

            // Mode — Single / Instructor radio options
            VStack(alignment: .leading, spacing: 12) {
                Text("Mode")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(.white)
                HStack(spacing: 28) {
                    radioOption("Single", isOn: mode == .single) { mode = .single }
                    radioOption("Instructor", isOn: mode == .instructor) { mode = .instructor }
                }
            }

            popupDivider

            // Settings
            popupRow(icon: "gearshape.fill", title: "Settings") {
                // TODO: open settings
            }

            popupDivider

            // Logout
            popupRow(icon: "rectangle.portrait.and.arrow.right", title: "Logout") {
                dismissAccount()
                auth.logout()
                onLogout()
            }

            Text(appVersion)
                .font(.system(size: 18, weight: .semibold))
                .italic()
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.08, green: 0.15, blue: 0.30),
                                 Color(red: 0.05, green: 0.10, blue: 0.22)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color(red: 0.30, green: 0.55, blue: 0.95), lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
    }

    private var popupDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.18))
            .frame(height: 1)
    }

    private func radioOption(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isOn ? Color(red: 0.30, green: 0.55, blue: 0.95) : .white.opacity(0.7))
                Text(title)
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }

    private func popupRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
                    .frame(width: 28)
                Text(title)
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    private func dismissAccount() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showAccount = false
        }
    }

    @ViewBuilder
    private var exerciseList: some View {
        if viewModel.isLoading && viewModel.exercises.isEmpty {
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(40)
        } else if let error = viewModel.errorMessage, viewModel.exercises.isEmpty {
            VStack(spacing: 8) {
                Text("Couldn't load exercises").foregroundStyle(.white)
                Text(error).font(.caption).foregroundStyle(.white.opacity(0.6))
                Button("Retry") { Task { await viewModel.load() } }
                    .tint(.green)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(40)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 24) {
                    ForEach(Array(viewModel.exercises.enumerated()), id: \.element.id) { index, exercise in
                        ExerciseCard(exercise: exercise, number: index + 1,
                                     onStart: { await start(exercise) },
                                     onReplay: { browsing = exercise })
                        .task { await viewModel.loadMoreIfNeeded(currentItem: exercise) }
                    }

                    if viewModel.isLoadingMore {
                        ProgressView()
                            .tint(.white)
                            .frame(width: 60)
                    }
                }
                .padding(24)
            }
        }
    }

    private var mapProviderPicker: some View {
        HStack(spacing: 12) {
            Text("Map")
                .font(.headline)
                .foregroundStyle(.white)

            Picker("Map", selection: provider) {
                ForEach(MapProvider.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.menu)
            .tint(.green)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }
}

#Preview {
    HomeScreen()
}
