import Observation
import UIKit

@Observable @MainActor
final class AppState {
    enum Tab: Hashable { case stacks, activity, settings }

    let settings: AppSettings
    let activity: ActivityStore
    var selectedTab: Tab
    /// Set when Portainer rejects the token; Settings shows it until a new token is saved.
    var authProblem: String?
    private(set) var hasToken: Bool
    private(set) var activeRun: RedeployRun?
    /// Bumped when the stacks list should reload (settings saved, redeploy finished).
    private(set) var stacksRevision = 0

    @ObservationIgnored private let keychain: KeychainStore
    @ObservationIgnored private let clientOverride: PortainerClient?
    @ObservationIgnored private let notifier = Notifier()

    init(
        settings: AppSettings = AppSettings(),
        activity: ActivityStore = ActivityStore(),
        keychain: KeychainStore = KeychainStore(),
        clientOverride: PortainerClient? = nil
    ) {
        self.settings = settings
        self.activity = activity
        self.keychain = keychain
        self.clientOverride = clientOverride
        let hasToken = clientOverride != nil || (try? keychain.read()) != nil
        self.hasToken = hasToken
        let configured = settings.serverURL != nil && hasToken && settings.environmentId != nil
        selectedTab = configured ? .stacks : .settings
    }

    var isConnectionConfigured: Bool { settings.serverURL != nil && hasToken }
    var isConfigured: Bool { isConnectionConfigured && settings.environmentId != nil }

    func makeClient() throws -> PortainerClient {
        if let clientOverride { return clientOverride }
        guard let url = settings.serverURL, let token = try keychain.read(), !token.isEmpty else {
            throw PortainerError.notConfigured
        }
        return LivePortainerClient(baseURL: url, token: token)
    }

    func saveToken(_ token: String) throws {
        try keychain.save(token.trimmingCharacters(in: .whitespacesAndNewlines))
        hasToken = true
        authProblem = nil
    }

    func forgetToken() {
        try? keychain.delete()
        hasToken = clientOverride != nil
    }

    func settingsChanged() {
        settings.save()
        stacksRevision += 1
    }

    func reportUnauthorized(openSettings: Bool) {
        authProblem = "Portainer rejected the API token. It may have expired or been revoked. "
            + "Create a new one in Portainer under My account → Access tokens and paste it here."
        if openSettings { selectedTab = .settings }
    }

    /// Starts a redeploy after the user confirmed it. Returns nil if one is already running.
    @discardableResult
    func startRedeploy(_ stack: Stack, repullImages: Bool, prune: Bool) -> RedeployRun? {
        guard activeRun == nil else { return nil }
        let run = RedeployRun(stack: stack, repullImages: repullImages, prune: prune)
        activeRun = run
        let notify = settings.notifyWhenFinished
        Task {
            if notify { await notifier.requestAuthorizationIfNeeded() }
            let background = BackgroundActivity(name: "Redeploy \(stack.name)")
            do {
                let client = try makeClient()
                await run.execute(client: client)
            } catch {
                run.fail(error: error)
            }
            finish(run)
            background.end()
        }
        return run
    }

    private func finish(_ run: RedeployRun) {
        activity.record(ActivityEntry(
            stackId: run.stack.id,
            stackName: run.stack.name,
            date: run.startedAt,
            succeeded: run.succeeded,
            message: run.message ?? "",
            duration: run.duration
        ))
        UINotificationFeedbackGenerator().notificationOccurred(run.succeeded ? .success : .error)
        if run.error == .unauthorized { reportUnauthorized(openSettings: false) }
        if settings.notifyWhenFinished && UIApplication.shared.applicationState != .active {
            let title = run.succeeded ? "\(run.stack.name) redeployed" : "\(run.stack.name) redeploy failed"
            let body = run.message ?? ""
            Task { await notifier.post(title: title, body: body) }
        }
        activeRun = nil
        stacksRevision += 1
    }
}

extension AppState {
    /// Fake server data, for previews and the `--demo` launch argument.
    static func demo() -> AppState {
        let defaults = UserDefaults(suiteName: "nl.r-huijts.phonetainer.demo") ?? .standard
        let settings = AppSettings(defaults: defaults)
        settings.serverAddress = "https://portainer.demo.ts.net"
        settings.environmentId = 1
        settings.environmentName = "local"
        return AppState(settings: settings, activity: ActivityStore(fileURL: nil), clientOverride: MockPortainerClient.demo())
    }
}
