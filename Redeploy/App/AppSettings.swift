import Foundation
import Observation

/// Non-secret settings, kept in UserDefaults. The API token lives in the Keychain (see AppState).
@Observable @MainActor
final class AppSettings {
    var serverAddress: String
    var environmentId: Int?
    var environmentName: String?
    var requireAuthentication: Bool
    var repullImagesByDefault: Bool
    var notifyWhenFinished: Bool

    @ObservationIgnored private let defaults: UserDefaults

    private enum Key {
        static let serverAddress = "serverAddress"
        static let environmentId = "environmentId"
        static let environmentName = "environmentName"
        static let requireAuthentication = "requireAuthentication"
        static let repullImagesByDefault = "repullImagesByDefault"
        static let notifyWhenFinished = "notifyWhenFinished"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        serverAddress = defaults.string(forKey: Key.serverAddress) ?? ""
        environmentId = defaults.object(forKey: Key.environmentId) as? Int
        environmentName = defaults.string(forKey: Key.environmentName)
        requireAuthentication = defaults.object(forKey: Key.requireAuthentication) as? Bool ?? true
        repullImagesByDefault = defaults.object(forKey: Key.repullImagesByDefault) as? Bool ?? true
        notifyWhenFinished = defaults.object(forKey: Key.notifyWhenFinished) as? Bool ?? true
    }

    func save() {
        defaults.set(serverAddress, forKey: Key.serverAddress)
        defaults.set(environmentId, forKey: Key.environmentId)
        defaults.set(environmentName, forKey: Key.environmentName)
        defaults.set(requireAuthentication, forKey: Key.requireAuthentication)
        defaults.set(repullImagesByDefault, forKey: Key.repullImagesByDefault)
        defaults.set(notifyWhenFinished, forKey: Key.notifyWhenFinished)
    }

    var serverURL: URL? { Self.normalizedURL(serverAddress) }

    var serverHost: String? { serverURL?.host }

    /// Tailscale addresses are 100.64.0.0/10 or MagicDNS names under ts.net.
    var isTailscaleAddress: Bool {
        guard let host = serverHost?.lowercased() else { return false }
        if host.hasSuffix(".ts.net") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    /// Accepts "host", "host:9443" or a full URL; defaults to HTTPS when no scheme is given.
    nonisolated static func normalizedURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }
}
