import Foundation

/// In-memory Portainer for previews, tests and demo mode (launch argument `--demo`).
final class MockPortainerClient: PortainerClient, @unchecked Sendable {
    var serverVersion: String? = "2.39.8"
    var environmentList: [PortainerEnvironment]
    var stackList: [Stack]
    var containersByProject: [String: [DockerContainer]]
    /// Thrown by every call when set.
    var error: PortainerError?
    /// Thrown by `redeploy` only.
    var redeployError: PortainerError?
    /// How many `stack(id:)` calls after a redeploy still report "deploying" (newer, async Portainer).
    var deployingPolls = 0
    /// Status reported once deploying is over: 1 active, 4 error.
    var statusAfterDeploy = 1
    var delay: Duration = .zero
    private(set) var redeployCalls: [(stackId: Int, repullImages: Bool, prune: Bool)] = []
    private var remainingDeployingPolls = 0

    init(
        environments: [PortainerEnvironment] = [],
        stacks: [Stack] = [],
        containersByProject: [String: [DockerContainer]] = [:]
    ) {
        environmentList = environments
        stackList = stacks
        self.containersByProject = containersByProject
    }

    func version() async throws -> String? {
        try await simulate()
        return serverVersion
    }

    func environments() async throws -> [PortainerEnvironment] {
        try await simulate()
        return environmentList
    }

    func stacks() async throws -> [Stack] {
        try await simulate()
        return stackList
    }

    func stack(id: Int) async throws -> Stack {
        try await simulate()
        guard var stack = stackList.first(where: { $0.id == id }) else {
            throw PortainerError.notFound("Stack \(id)")
        }
        if remainingDeployingPolls > 0 {
            remainingDeployingPolls -= 1
            stack.status = 3
        }
        return stack
    }

    func containers(endpointId: Int, project: String) async throws -> [DockerContainer] {
        try await simulate()
        return containersByProject[project] ?? []
    }

    func redeploy(stack: Stack, repullImages: Bool, prune: Bool) async throws -> Stack {
        try await simulate()
        redeployCalls.append((stack.id, repullImages, prune))
        if let redeployError { throw redeployError }
        guard let index = stackList.firstIndex(where: { $0.id == stack.id }) else {
            throw PortainerError.notFound("Stack \(stack.id)")
        }
        stackList[index].updateDate = Int64(Date().timeIntervalSince1970)
        stackList[index].status = statusAfterDeploy
        if statusAfterDeploy == 4 {
            stackList[index].deploymentStatus = [DeploymentStatusEntry(status: 4, time: nil, message: "compose up failed: image not found")]
        }
        remainingDeployingPolls = deployingPolls
        var response = stackList[index]
        if deployingPolls > 0 { response.status = 3 }
        return response
    }

    private func simulate() async throws {
        if delay > .zero { try await Task.sleep(for: delay) }
        if let error { throw error }
    }
}

extension MockPortainerClient {
    static func demo() -> MockPortainerClient {
        let now = Int64(Date().timeIntervalSince1970)
        func git(_ branch: String, _ hash: String) -> GitConfig {
            GitConfig(url: "https://github.com/example/homelab.git", referenceName: "refs/heads/\(branch)",
                      configFilePath: "docker-compose.yml", configHash: hash, authentication: nil)
        }
        func container(_ name: String, _ state: String, _ status: String) -> DockerContainer {
            DockerContainer(id: UUID().uuidString, names: ["/\(name)"], image: "\(name):latest", state: state, status: status, labels: nil)
        }
        let client = MockPortainerClient(
            environments: [PortainerEnvironment(id: 1, name: "local", type: 1, status: 1)],
            stacks: [
                Stack(id: 1, name: "homepage", type: 2, endpointId: 1, status: 1, env: [],
                      gitConfig: git("main", "4f2c9a1e0b7d"), updateDate: now - 3 * 3600),
                Stack(id: 2, name: "immich", type: 2, endpointId: 1, status: 1, env: [],
                      gitConfig: git("main", "a91be03c55f2"), updateDate: now - 2 * 86400),
                Stack(id: 3, name: "paperless", type: 2, endpointId: 1, status: 2, env: [],
                      gitConfig: git("release", "77d0e1f9aa31"), updateDate: now - 9 * 86400),
                Stack(id: 4, name: "adguard", type: 2, endpointId: 1, status: 1, env: [], gitConfig: nil,
                      updateDate: now - 30 * 86400),
            ],
            containersByProject: [
                "homepage": [container("homepage", "running", "Up 3 hours (healthy)"),
                             container("dockerproxy", "running", "Up 3 hours")],
                "immich": [container("immich-server", "running", "Up 2 days"),
                           container("immich-ml", "exited", "Exited (137) 1 hour ago"),
                           container("immich-redis", "running", "Up 2 days"),
                           container("immich-db", "running", "Up 2 days")],
                "paperless": [container("paperless", "exited", "Exited (0) 9 days ago")],
                "adguard": [container("adguard", "running", "Up 30 days")],
            ]
        )
        client.delay = .milliseconds(600)
        return client
    }
}
