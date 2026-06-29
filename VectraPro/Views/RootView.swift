//
//  RootView.swift
//  VectraPro
//
//  Onboarding flow coordinator: Organization ID → Login → Home.
//

import SwiftUI

enum AppRoute: Hashable {
    case login
}

struct RootView: View {

    @State private var path: [AppRoute] = []
    @State private var isLoggedIn = false

    var body: some View {
        Group {
            if isLoggedIn {
                // Logged in → the main app (HomeScreen owns its own NavigationStack).
                HomeScreen()
            } else {
                NavigationStack(path: $path) {
                    OrgIDScreen(onConfigured: { path.append(.login) })
                        .navigationDestination(for: AppRoute.self) { route in
                            switch route {
                            case .login:
                                LoginScreen(
                                    onLogin: { isLoggedIn = true },
                                    onChangeOrganization: { path.removeAll() }
                                )
                            }
                        }
                }
                .tint(.green)
            }
        }
    }
}

#Preview {
    RootView()
}
