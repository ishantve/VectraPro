//
//  OrgIDScreen.swift
//  VectraPro
//
//  First onboarding screen — asks for the Organization ID, resolves it against
//  the UDC API, saves the matched config locally, then advances to login.
//

import SwiftUI

struct OrgIDScreen: View {

    /// Called once the organization is resolved and saved.
    var onConfigured: () -> Void

    @State private var organizationID = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var trimmedID: String {
        organizationID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                VStack(spacing: 8) {
                    Text("VectraPro")
                        .font(.largeTitle.bold())
                        .foregroundStyle(.white)
                    Text("Enter your Organization ID to continue")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                }

                VStack(alignment: .leading, spacing: 8) {
                    TextField("", text: $organizationID, prompt: Text("Organization ID").foregroundColor(.white.opacity(0.4)))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .onSubmit { submit() }
                        .foregroundStyle(.white)
                        .padding()
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.15), lineWidth: 1))

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Button(action: submit) {
                    HStack {
                        if isLoading { ProgressView().tint(.black) }
                        Text(isLoading ? "Checking…" : "Next")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(canSubmit ? Color.green : Color.white.opacity(0.15),
                                in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(canSubmit ? .black : .white.opacity(0.5))
                }
                .disabled(!canSubmit)

                Spacer()
                Spacer()
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, 32)
        }
    }

    private var canSubmit: Bool { !trimmedID.isEmpty && !isLoading }

    private func submit() {
        guard canSubmit else { return }
        Task { await resolve() }
    }

    @MainActor
    private func resolve() async {
        isLoading = true
        errorMessage = nil
        do {
            try await APIEnvironment.configure(organizationID: trimmedID)
            isLoading = false
            onConfigured()
        } catch {
            isLoading = false
            if let apiError = error as? APIError, case .organizationNotFound = apiError {
                errorMessage = "No organization found for “\(trimmedID)”."
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    OrgIDScreen(onConfigured: {})
}
