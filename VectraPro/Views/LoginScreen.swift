//
//  LoginScreen.swift
//  VectraPro
//
//  Second onboarding screen — username / password login, with an option to go
//  back and change the Organization ID.
//

import SwiftUI
import NetworkKit

struct LoginScreen: View {

    /// Called when "Log in" succeeds (auth wiring is a TODO).
    var onLogin: () -> Void
    /// Called when the user wants to pick a different organization.
    var onChangeOrganization: () -> Void

    @StateObject private var viewModel = LoginViewModel()
    @State private var username = ""
    @State private var password = ""
    @State private var nickname = ""
    @State private var showPassword = false
    @State private var isLoading = false
    @State private var toast: Toast?

    struct Toast: Equatable {
        let message: String
        let isSuccess: Bool
    }

    /// The selected organization's saved config.
    private var config: AirtableConfig? { ConfigStore.shared.current() }

    /// When the org's `Nickname` is "Allowed", login is via a nickname instead
    /// of username + password.
    private var nicknameAllowed: Bool {
        config?.nickname.caseInsensitiveCompare("Allowed") == .orderedSame
    }

    /// Validation message for the username (accepts a plain username OR an
    /// email; no spaces). `nil` means valid. Shown only once the user types.
    private var usernameError: String? {
        let value = username.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        if value.contains("@"), !isValidEmail(value) {
            return "Enter a valid email address."
        }
        return nil
    }

    private func isValidEmail(_ value: String) -> Bool {
        let pattern = "^[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$"
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private var canLogIn: Bool {
        if nicknameAllowed {
            return !nickname.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return !username.trimmingCharacters(in: .whitespaces).isEmpty
            && usernameError == nil
            && !password.isEmpty
    }

    private var canSubmit: Bool { canLogIn && !isLoading }

    /// Build a readable error message, including the server's response body for
    /// non-2xx responses (so a 403 shows *why*).
    private func message(for error: Error) -> String {
        if case let APIError.unacceptableStatus(code, data) = error {
            let body = String(data: data, encoding: .utf8) ?? ""
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Server error \(code)." : "Error \(code): \(trimmed)"
        }
        return error.localizedDescription
    }

    private func performLogin() {
        guard canSubmit else { return }
        Task {
            isLoading = true
            toast = nil
            do {
                try await viewModel.signIn(
                    nicknameAllowed: nicknameAllowed,
                    nickname: nickname,
                    username: username.trimmingCharacters(in: .whitespaces),
                    password: password
                )

                isLoading = false
                toast = Toast(message: "Login successful", isSuccess: true)
                // Let the success message show briefly, then continue.
                try? await Task.sleep(for: .seconds(1))
                onLogin()
            } catch {
                isLoading = false
                toast = Toast(message: message(for: error), isSuccess: false)
                // Auto-dismiss the failure message.
                try? await Task.sleep(for: .seconds(5))
                if toast?.isSuccess == false { toast = nil }
            }
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                VStack(spacing: 8) {
                    Text("Log in")
                        .font(.largeTitle.bold())
                        .foregroundStyle(.white)
                    if let org = config?.organizationID {
                        Text(org)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }

                VStack(spacing: 12) {
                    if nicknameAllowed {
                        TextField("", text: $nickname, prompt: Text("Nickname").foregroundColor(.white.opacity(0.4)))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .onSubmit { performLogin() }
                            // No special characters; normalize to lowercase
                            // (nickname is case-insensitive).
                            .onChange(of: nickname) { _, newValue in
                                let sanitized = newValue
                                    .filter { $0.isLetter || $0.isNumber }
                                    .lowercased()
                                if sanitized != newValue { nickname = sanitized }
                            }
                            .styledField()
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("", text: $username, prompt: Text("Email or Username").foregroundColor(.white.opacity(0.4)))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .textContentType(.username)
                                .keyboardType(.emailAddress)
                                // No spaces allowed in the username/email.
                                .onChange(of: username) { _, newValue in
                                    if newValue.contains(where: { $0.isWhitespace }) {
                                        username = newValue.filter { !$0.isWhitespace }
                                    }
                                }
                                .styledField()

                            if let usernameError {
                                Text(usernameError)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }

                        passwordField
                    }
                }

                VStack(spacing: 8) {
                    Button {
                        performLogin()
                    } label: {
                        HStack {
                            if isLoading { ProgressView().tint(.black) }
                            Text(isLoading ? "Logging in…" : "Log in")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(canSubmit ? Color.green : Color.white.opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(canSubmit ? .black : .white.opacity(0.5))
                    }
                    .disabled(!canSubmit)
                }

                Button(action: onChangeOrganization) {
                    Text("Change Organization ID")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.8))
                }

                Spacer()
                Spacer()
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, 32)
        }
        .navigationBarBackButtonHidden(true)
        .overlay(alignment: .top) {
            if let toast {
                HStack(spacing: 10) {
                    Image(systemName: toast.isSuccess ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    Text(toast.message)
                        .font(.subheadline.weight(.medium))
                        .multilineTextAlignment(.leading)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    (toast.isSuccess ? Color.green : Color.red).opacity(0.9),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: toast)
    }

    /// Password field, hidden by default, with an eye button to toggle visibility.
    private var passwordField: some View {
        HStack(spacing: 8) {
            Group {
                if showPassword {
                    TextField("", text: $password, prompt: Text("Password").foregroundColor(.white.opacity(0.4)))
                } else {
                    SecureField("", text: $password, prompt: Text("Password").foregroundColor(.white.opacity(0.4)))
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.password)
            .foregroundStyle(.white)
            .submitLabel(.go)
            .onSubmit { performLogin() }

            Button {
                showPassword.toggle()
            } label: {
                Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding()
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.15), lineWidth: 1))
    }
}

/// Shared dark text-field styling for the login fields.
private extension View {
    func styledField() -> some View {
        self
            .foregroundStyle(.white)
            .padding()
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.15), lineWidth: 1))
    }
}

#Preview {
    LoginScreen(onLogin: {}, onChangeOrganization: {})
}
