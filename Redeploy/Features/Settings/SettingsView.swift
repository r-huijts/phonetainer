import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var serverAddress = ""
    @State private var tokenDraft = ""
    @State private var environments: [PortainerEnvironment] = []
    @State private var testResult: TestResult?
    @State private var isTesting = false

    private enum TestResult {
        case success(String)
        case failure(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let problem = appState.authProblem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.dangerText)
                            .font(.subheadline)
                    }
                }

                Section {
                    TextField("portainer.your-tailnet.ts.net", text: $serverAddress)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Server address")
                } header: {
                    Text("Server address")
                } footer: {
                    Text("Your Portainer address on your tailnet. HTTPS is assumed when you leave out the scheme.")
                }

                Section {
                    SecureField(appState.hasToken ? "Saved. Paste a new token to replace it" : "ptr_…", text: $tokenDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("API token")
                    if appState.hasToken {
                        Button("Remove saved token", role: .destructive) {
                            appState.forgetToken()
                            testResult = nil
                        }
                    }
                } header: {
                    Text("API token")
                } footer: {
                    Label("Stored in the iOS Keychain", systemImage: "lock.fill")
                }

                Section {
                    Button {
                        Task { await saveAndTest() }
                    } label: {
                        HStack {
                            Text("Save and test connection")
                            Spacer()
                            if isTesting { ProgressView() }
                        }
                    }
                    .disabled(isTesting)

                    if let testResult {
                        testResultRow(testResult)
                    }

                    Picker("Environment", selection: environmentSelection) {
                        if appState.settings.environmentId == nil {
                            Text("None").tag(Int?.none)
                        }
                        ForEach(pickerEnvironments) { environment in
                            Text(environment.name).tag(Optional(environment.id))
                        }
                    }
                    .disabled(pickerEnvironments.isEmpty)
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Testing the connection loads your environments.")
                }

                Section("Safety") {
                    Toggle("Require \(DeviceAuthentication.methodName) to redeploy", isOn: setting(\.requireAuthentication))
                    Toggle("Re-pull images by default", isOn: setting(\.repullImagesByDefault))
                    Toggle("Notify when finished", isOn: setting(\.notifyWhenFinished))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Settings")
            .toolbarBackground(Theme.surface, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
            .onAppear {
                if serverAddress.isEmpty { serverAddress = appState.settings.serverAddress }
            }
            .task { await loadEnvironmentsQuietly() }
        }
    }

    /// The loaded environments, or the saved one before they are loaded, so the picker always has its selection.
    private var pickerEnvironments: [PortainerEnvironment] {
        if !environments.isEmpty { return environments }
        guard let id = appState.settings.environmentId else { return [] }
        return [PortainerEnvironment(id: id, name: appState.settings.environmentName ?? "Environment \(id)")]
    }

    private var environmentSelection: Binding<Int?> {
        Binding(
            get: { appState.settings.environmentId },
            set: { id in
                appState.settings.environmentId = id
                appState.settings.environmentName = pickerEnvironments.first(where: { $0.id == id })?.name
                appState.settingsChanged()
            }
        )
    }

    private func setting(_ keyPath: ReferenceWritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { appState.settings[keyPath: keyPath] },
            set: { value in
                appState.settings[keyPath: keyPath] = value
                appState.settings.save()
            }
        )
    }

    @ViewBuilder
    private func testResultRow(_ result: TestResult) -> some View {
        switch result {
        case .success(let text):
            Label(text, systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.successText)
        case .failure(let text):
            Label(text, systemImage: "xmark.octagon.fill")
                .foregroundStyle(Theme.dangerText)
        }
    }

    private func saveAndTest() async {
        testResult = nil
        guard let url = AppSettings.normalizedURL(serverAddress) else {
            testResult = .failure("Enter an address like portainer.your-tailnet.ts.net or https://100.101.102.103:9443.")
            return
        }
        serverAddress = url.absoluteString
        appState.settings.serverAddress = url.absoluteString
        if !tokenDraft.isEmpty {
            do {
                try appState.saveToken(tokenDraft)
                tokenDraft = ""
            } catch {
                testResult = .failure("Couldn't save the token in the Keychain (\(error.localizedDescription)).")
                return
            }
        }
        appState.settingsChanged()
        guard appState.hasToken else {
            testResult = .failure("Paste an API token first. Create one in Portainer under My account → Access tokens.")
            return
        }

        isTesting = true
        defer { isTesting = false }
        do {
            let client = try appState.makeClient()
            let loaded = try await client.environments()
            let version = try? await client.version()
            environments = loaded
            if let current = appState.settings.environmentId, loaded.contains(where: { $0.id == current }) {
                appState.settings.environmentName = loaded.first(where: { $0.id == current })?.name
            } else {
                appState.settings.environmentId = loaded.first?.id
                appState.settings.environmentName = loaded.first?.name
            }
            appState.authProblem = nil
            appState.settingsChanged()
            var parts = ["Reachable"]
            if let version { parts.append("Portainer \(version)") }
            parts.append(loaded.count == 1 ? "1 environment" : "\(loaded.count) environments")
            testResult = .success(parts.joined(separator: " · "))
        } catch {
            let portainerError = LivePortainerClient.mapTransportError(error)
            if portainerError == .unauthorized { appState.reportUnauthorized(openSettings: false) }
            testResult = .failure(portainerError.localizedDescription)
        }
    }

    private func loadEnvironmentsQuietly() async {
        guard appState.isConnectionConfigured, environments.isEmpty,
              let client = try? appState.makeClient(),
              let loaded = try? await client.environments() else { return }
        environments = loaded
    }
}

#Preview {
    SettingsView().environment(AppState.demo())
}
