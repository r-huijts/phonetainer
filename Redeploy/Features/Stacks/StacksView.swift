import SwiftUI

/// The sheet shown from the stacks list. Confirm and progress share an id so
/// that starting a redeploy swaps the sheet's content instead of re-presenting it.
enum StackSheet: Identifiable {
    case confirm(Stack)
    case progress(RedeployRun)

    var id: Int {
        switch self {
        case .confirm(let stack): return stack.id
        case .progress(let run): return run.stack.id
        }
    }
}

struct StacksView: View {
    @Environment(AppState.self) private var appState
    @State private var model = StacksViewModel()
    @State private var sheet: StackSheet?

    private struct ReloadKey: Hashable {
        let server: String
        let environmentId: Int?
        let hasToken: Bool
        let revision: Int
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.gutter) {
                    if appState.isConfigured {
                        connectionLine
                    }
                    content
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, Theme.gutter)
            }
            .background(Theme.background)
            .navigationTitle("Stacks")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await reload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh")
                    .disabled(!appState.isConfigured)
                }
            }
            .refreshable { await reload() }
            .task(id: reloadKey) { await reload() }
            .toolbarBackground(Theme.surface, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
            .sheet(item: $sheet) { item in
                switch item {
                case .confirm(let stack):
                    ConfirmSheet(stack: stack) { run in
                        sheet = .progress(run)
                    }
                case .progress(let run):
                    RedeployProgressView(run: run)
                }
            }
        }
    }

    private var reloadKey: ReloadKey {
        ReloadKey(
            server: appState.settings.serverAddress,
            environmentId: appState.settings.environmentId,
            hasToken: appState.hasToken,
            revision: appState.stacksRevision
        )
    }

    private var connectionLine: some View {
        let host = appState.settings.serverHost ?? ""
        let via = appState.settings.isTailscaleAddress ? "Connected via Tailscale" : "Connected"
        let text: String
        let symbol: String
        let color: Color
        switch model.state {
        case .failed:
            text = "Not reachable · \(host)"
            symbol = "exclamationmark.circle.fill"
            color = Theme.dangerText
        case .idle, .loading:
            text = "Connecting · \(host)"
            symbol = "circle.dotted"
            color = Theme.secondaryText
        case .loaded:
            text = "\(via) · \(host)"
            symbol = "circle.fill"
            color = Theme.successText
        }
        return Label {
            Text(text).foregroundStyle(Theme.secondaryText)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color).imageScale(.small)
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var content: some View {
        if !appState.isConfigured {
            notConfigured
        } else {
            if case .failed(let message) = model.state {
                errorCard(message)
            }
            if model.rows.isEmpty {
                switch model.state {
                case .idle, .loading:
                    ProgressView("Loading stacks…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                case .loaded:
                    ContentUnavailableView(
                        "No stacks",
                        systemImage: "square.stack.3d.up.slash",
                        description: Text("This environment has no stacks yet.")
                    )
                case .failed:
                    EmptyView()
                }
            }
            ForEach(model.rows) { row in
                StackCard(
                    row: row,
                    isRedeploying: appState.activeRun?.stack.id == row.id,
                    isBlocked: appState.activeRun != nil,
                    onRedeploy: { sheet = .confirm(row.stack) },
                    onShowProgress: {
                        if let run = appState.activeRun { sheet = .progress(run) }
                    }
                )
            }
        }
    }

    private var notConfigured: some View {
        ContentUnavailableView {
            Label("Not connected", systemImage: "network.slash")
        } description: {
            Text("Add your Portainer address, an API token and an environment in Settings.")
        } actions: {
            Button("Open Settings") { appState.selectedTab = .settings }
                .buttonStyle(PrimaryButtonStyle())
                .frame(maxWidth: 240)
        }
        .padding(.top, 48)
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.dangerText)
                .font(.subheadline)
            if model.lastError == .unauthorized {
                Button("Open Settings") { appState.selectedTab = .settings }
                    .buttonStyle(SecondaryButtonStyle())
            } else {
                Button("Try again") { Task { await reload() } }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .card()
    }

    private func reload() async {
        guard appState.isConfigured, let environmentId = appState.settings.environmentId else {
            model.reset()
            return
        }
        do {
            let client = try appState.makeClient()
            await model.load(client: client, environmentId: environmentId)
            if model.lastError == .unauthorized {
                appState.reportUnauthorized(openSettings: true)
            }
        } catch {
            model.reset()
        }
    }
}

#Preview {
    StacksView().environment(AppState.demo())
}
