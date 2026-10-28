import Foundation

// Codable mirrors of the Portainer JSON this app uses. Every field that is not
// needed to identify an object is optional, so older and newer Portainer
// versions decode without errors. See docs/api-notes.md.

/// A Portainer environment. The API calls these "endpoints".
struct PortainerEnvironment: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    var type: Int?
    var status: Int?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", type = "Type", status = "Status"
    }
}

struct Stack: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    var type: Int?
    var endpointId: Int?
    var status: Int?
    var env: [EnvironmentVariable]?
    var gitConfig: GitConfig?
    var updateDate: Int64?
    var updatedBy: String?
    var option: StackOption?
    var currentDeploymentInfo: DeploymentInfo?
    var deploymentStatus: [DeploymentStatusEntry]?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", type = "Type", endpointId = "EndpointId", status = "Status"
        case env = "Env", gitConfig = "GitConfig", updateDate = "UpdateDate", updatedBy = "UpdatedBy"
        case option = "Option", currentDeploymentInfo = "CurrentDeploymentInfo"
        case deploymentStatus = "DeploymentStatus"
    }
}

struct EnvironmentVariable: Codable, Hashable, Sendable {
    let name: String
    let value: String
}

struct GitConfig: Codable, Hashable, Sendable {
    var url: String?
    var referenceName: String?
    var configFilePath: String?
    var configHash: String?
    var authentication: GitAuthentication?

    enum CodingKeys: String, CodingKey {
        case url = "URL", referenceName = "ReferenceName", configFilePath = "ConfigFilePath"
        case configHash = "ConfigHash", authentication = "Authentication"
    }
}

/// Portainer blanks the password in responses; only the username is useful.
struct GitAuthentication: Codable, Hashable, Sendable {
    var username: String?
    var authorizationType: Int?

    enum CodingKeys: String, CodingKey {
        case username = "Username", authorizationType = "AuthorizationType"
    }
}

struct StackOption: Codable, Hashable, Sendable {
    var prune: Bool?

    enum CodingKeys: String, CodingKey {
        case prune = "Prune"
    }
}

/// Newer Portainer versions only: what is actually deployed.
struct DeploymentInfo: Codable, Hashable, Sendable {
    var configHash: String?

    enum CodingKeys: String, CodingKey {
        case configHash = "ConfigHash"
    }
}

/// Newer Portainer versions only: status history of the current deployment.
struct DeploymentStatusEntry: Codable, Hashable, Sendable {
    var status: Int?
    var time: Int64?
    var message: String?

    enum CodingKeys: String, CodingKey {
        case status = "Status", time = "Time", message = "Message"
    }
}

struct DockerContainer: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var names: [String]?
    var image: String?
    var state: String?
    /// Human-readable, e.g. "Up 3 minutes (healthy)".
    var status: String?
    var labels: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id = "Id", names = "Names", image = "Image", state = "State", status = "Status", labels = "Labels"
    }

    var displayName: String {
        let name = names?.first ?? String(id.prefix(12))
        return name.hasPrefix("/") ? String(name.dropFirst()) : name
    }

    var isRunning: Bool { state == "running" }
    var isHealthStarting: Bool { status?.contains("(health: starting)") ?? false }
    var isUnhealthy: Bool { status?.contains("(unhealthy)") ?? false }
}

struct VersionInfo: Decodable, Sendable {
    var serverVersion: String?
    var version: String?

    enum CodingKeys: String, CodingKey {
        case serverVersion = "ServerVersion", version = "Version"
    }
}

struct ServerErrorBody: Decodable, Sendable {
    var message: String?
    var details: String?

    var text: String? {
        let parts = [message, details].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ": ")
    }
}

// MARK: - Stack helpers

extension Stack {
    enum Kind { case swarm, compose, kubernetes, unknown }

    /// Portainer's stack status: 1 active, 2 inactive, 3 deploying, 4 error (3 and 4 only on newer versions).
    enum Lifecycle { case active, inactive, deploying, error, unknown }

    var kind: Kind {
        switch type {
        case 1: return .swarm
        case 2: return .compose
        case 3: return .kubernetes
        default: return .unknown
        }
    }

    var lifecycle: Lifecycle {
        switch status {
        case 1: return .active
        case 2: return .inactive
        case 3: return .deploying
        case 4: return .error
        default: return .unknown
        }
    }

    var isGitBased: Bool { gitConfig != nil }

    var canRedeploy: Bool { unavailableReason == nil }

    /// Why this stack can't be redeployed from the app, or nil if it can.
    var unavailableReason: String? {
        if !isGitBased { return "Not Git-based" }
        if kind != .compose { return "Only Compose stacks are supported" }
        if endpointId == nil { return "No environment assigned" }
        return nil
    }

    var branch: String? {
        guard let ref = gitConfig?.referenceName, !ref.isEmpty else { return nil }
        for prefix in ["refs/heads/", "refs/tags/"] where ref.hasPrefix(prefix) {
            return String(ref.dropFirst(prefix.count))
        }
        return ref
    }

    var commit: String? {
        let candidates = [currentDeploymentInfo?.configHash, gitConfig?.configHash]
        return candidates.compactMap { $0 }.first { !$0.isEmpty }
    }

    var shortCommit: String? { commit.map { String($0.prefix(7)) } }

    var updatedAt: Date? {
        guard let updateDate, updateDate > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(updateDate))
    }

    var latestDeploymentError: String? {
        deploymentStatus?.last(where: { $0.status == 4 })?.message
    }
}

// MARK: - Redeploy request

/// Body for `PUT /api/stacks/{id}/git/redeploy`.
///
/// Portainer 2.39 overwrites the branch and env vars with whatever is sent
/// (empty included) and only uses the stored Git credentials when
/// `RepositoryAuthentication` is true, so this always sends the stack's
/// current values back. Newer versions treat these the same way or ignore them.
struct RedeployRequest: Encodable, Equatable, Sendable {
    var repositoryReferenceName: String
    var env: [EnvironmentVariable]
    var prune: Bool
    var repullImageAndRedeploy: Bool
    /// Deprecated alias of `repullImageAndRedeploy` since Portainer 2.36.
    var pullImage: Bool
    var repositoryAuthentication: Bool
    var repositoryUsername: String?
    /// Empty keeps the password Portainer has stored.
    var repositoryPassword: String?
    var repositoryAuthorizationType: Int?

    enum CodingKeys: String, CodingKey {
        case repositoryReferenceName = "RepositoryReferenceName", env = "Env", prune = "Prune"
        case repullImageAndRedeploy = "RepullImageAndRedeploy", pullImage = "PullImage"
        case repositoryAuthentication = "RepositoryAuthentication", repositoryUsername = "RepositoryUsername"
        case repositoryPassword = "RepositoryPassword", repositoryAuthorizationType = "RepositoryAuthorizationType"
    }

    init(stack: Stack, repullImages: Bool, prune: Bool) {
        repositoryReferenceName = stack.gitConfig?.referenceName ?? ""
        env = stack.env ?? []
        self.prune = prune
        repullImageAndRedeploy = repullImages
        pullImage = repullImages
        if let auth = stack.gitConfig?.authentication {
            repositoryAuthentication = true
            repositoryUsername = auth.username ?? ""
            repositoryPassword = ""
            repositoryAuthorizationType = auth.authorizationType
        } else {
            repositoryAuthentication = false
        }
    }
}

// MARK: - Health

struct StackHealth: Equatable, Sendable {
    let running: Int
    let total: Int
    let starting: Int
    let unhealthy: Int

    init(running: Int, total: Int, starting: Int = 0, unhealthy: Int = 0) {
        self.running = running
        self.total = total
        self.starting = starting
        self.unhealthy = unhealthy
    }

    init(containers: [DockerContainer]) {
        running = containers.filter(\.isRunning).count
        total = containers.count
        starting = containers.filter(\.isHealthStarting).count
        unhealthy = containers.filter(\.isUnhealthy).count
    }

    var allRunning: Bool { total > 0 && running == total }
    var isHealthy: Bool { allRunning && starting == 0 && unhealthy == 0 }

    var failureDescription: String {
        if total == 0 { return "No containers were found for this stack." }
        if unhealthy > 0 { return "\(unhealthy) of \(total) containers report unhealthy." }
        return "Only \(running) of \(total) containers are running."
    }
}

/// What the status chip on a stack card shows.
enum StackDisplayStatus: Equatable {
    case running(Int, Int)
    case degraded(Int, Int)
    case stopped
    case deploying
    case failed
    case unknown

    init(stack: Stack, health: StackHealth?) {
        if stack.lifecycle == .deploying {
            self = .deploying
            return
        }
        guard let health else {
            self = .unknown
            return
        }
        if health.running == 0 {
            self = stack.lifecycle == .error ? .failed : .stopped
        } else if health.running == health.total && health.unhealthy == 0 {
            self = .running(health.running, health.total)
        } else {
            self = .degraded(health.running, health.total)
        }
    }
}
