import SwiftUI
import SwiftData

/// The signed-out content of the library tab: the hero screen and the sign-in
/// form. Owns no session state of its own — `RootView` holds the
/// `LoginViewModel` and decides which branch of that tab to show.
struct SignInView: View {
    @Bindable var viewModel: LoginViewModel

    @Environment(\.modelContext) private var modelContext

    @State private var showLoginForm = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case serverURL
        case username
        case password
    }

    var body: some View {
        Group {
            if showLoginForm {
                loginFormView
            } else {
                heroView
            }
        }
        .background(.black)
        .onChange(of: viewModel.phase) { _, newPhase in
            if case .idle = newPhase {
                showLoginForm = false
            }
        }
    }

    // MARK: - Hero

    /// No Factory Reset button here any more. Settings is now a permanent tab
    /// reachable signed out, and `SettingsView.factoryReset()` does strictly
    /// more than the old hero button did (it also cancels in-flight downloads
    /// and clears the SwiftData model types).
    private var heroView: some View {
        VStack(spacing: 0) {
            Spacer()

            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)

            Text("ARMFIN")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .tracking(2)
                .padding(.top, 6)

            Spacer()

            Button {
                showLoginForm = true
            } label: {
                Text("Sign In")
                    .font(.footnote)
                    .fontWeight(.medium)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Login form

    private var loginFormView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                formHeader

                TextField("your-server:8096", text: $viewModel.serverURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .disabled(viewModel.isBusy || viewModel.isServerValidated)
                    .focused($focusedField, equals: .serverURL)
                    .submitLabel(.go)
                    .onSubmit { validateServer() }

                if viewModel.isServerValidated {
                    validatedServerRow

                    if let code = viewModel.quickConnectCode {
                        quickConnectPendingView(code: code)
                    } else if viewModel.phase == .quickConnectStarting {
                        ProgressView("Requesting code\u{2026}")
                            .frame(maxWidth: .infinity)
                    } else {
                        credentialsSection
                    }
                } else {
                    connectButton
                }

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red.opacity(0.9))
                }

                if viewModel.isBusy {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
        .scrollContentBackground(.hidden)
        .onDisappear {
            // Tears down the Quick Connect poll loop the moment this screen
            // isn't visible — including the success path, where the library
            // tab swaps this branch out for the browse UI. Required so the
            // bounded poll (LoginViewModel.runQuickConnectFlow) never outlives
            // the screen that started it, per soul.md §2.1.
            viewModel.cancelQuickConnect()
        }
    }

    private var formHeader: some View {
        HStack {
            Button {
                showLoginForm = false
            } label: {
                Image(systemName: "chevron.left")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")

            Spacer()

            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)

            Spacer()
            Color.clear.frame(width: 20, height: 20)
        }
        .padding(.bottom, 4)
    }

    private var validatedServerRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption2)
            Text(viewModel.serverURL)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
            Spacer()
            Button {
                viewModel.resetServerValidation()
                focusedField = .serverURL
            } label: {
                Text("Edit")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
    }

    private var credentialsSection: some View {
        Group {
            Button {
                viewModel.startQuickConnect(context: modelContext)
            } label: {
                Text("Quick Connect")
                    .font(.footnote)
                    .fontWeight(.medium)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isBusy)

            Text("or sign in with username & password")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .center)

            TextField("Username", text: $viewModel.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .disabled(viewModel.isBusy)
                .focused($focusedField, equals: .username)
                .submitLabel(.next)
                .onSubmit { focusedField = .password }

            SecureField("Password", text: $viewModel.password)
                .disabled(viewModel.isBusy)
                .focused($focusedField, equals: .password)
                .submitLabel(.go)
                .onSubmit { signIn() }

            Button {
                signIn()
            } label: {
                Text("Sign In")
                    .font(.footnote)
                    .fontWeight(.medium)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.username.isEmpty || viewModel.isBusy)
        }
    }

    private var connectButton: some View {
        Button {
            validateServer()
        } label: {
            Text("Connect")
                .font(.footnote)
                .fontWeight(.medium)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(viewModel.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isBusy)
    }

    private func quickConnectPendingView(code: String) -> some View {
        VStack(spacing: 8) {
            Text(code)
                .font(.system(.title2, design: .monospaced, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)

            Text("Enter this code in Jellyfin on another device")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)

            ProgressView()

            Button {
                viewModel.cancelQuickConnect()
            } label: {
                Text("Cancel")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func validateServer() {
        Task {
            await viewModel.validateServer()
            if viewModel.isServerValidated {
                focusedField = .username
            }
        }
    }

    private func signIn() {
        Task { await viewModel.signIn(context: modelContext) }
    }
}
