import XCTest
@testable import Redeploy

final class ModelDecodingTests: XCTestCase {
    func testDecodesStackList() throws {
        let stacks = try Fixture.decode([Stack].self, from: "stacks")
        XCTAssertEqual(stacks.count, 3)

        let git = stacks[0]
        XCTAssertEqual(git.id, 12)
        XCTAssertEqual(git.name, "spike-test")
        XCTAssertEqual(git.endpointId, 3)
        XCTAssertEqual(git.kind, .compose)
        XCTAssertEqual(git.lifecycle, .active)
        XCTAssertEqual(git.branch, "main")
        XCTAssertEqual(git.shortCommit, "4f2c9a1")
        XCTAssertEqual(git.env?.count, 2)
        XCTAssertEqual(git.gitConfig?.authentication?.authorizationType, 0)
        XCTAssertEqual(git.updatedAt, Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertTrue(git.canRedeploy)

        let plain = stacks[1]
        XCTAssertNil(plain.gitConfig)
        XCTAssertNil(plain.updatedAt, "UpdateDate 0 means never")
        XCTAssertEqual(plain.unavailableReason, "Not Git-based")

        let swarm = stacks[2]
        XCTAssertEqual(swarm.kind, .swarm)
        XCTAssertEqual(swarm.branch, "v1.2.0")
        XCTAssertNil(swarm.env)
        XCTAssertEqual(swarm.unavailableReason, "Only Compose stacks are supported")
    }

    func testDecodesDeployingStackFromNewerPortainer() throws {
        let stack = try Fixture.decode(Stack.self, from: "stack-deploying")
        XCTAssertEqual(stack.lifecycle, .deploying)
        XCTAssertEqual(stack.commit, "9999999aaaabbbbcccc")
        XCTAssertNil(stack.latestDeploymentError)
    }

    func testDecodesDeploymentError() throws {
        let stack = try Fixture.decode(Stack.self, from: "stack-error")
        XCTAssertEqual(stack.lifecycle, .error)
        XCTAssertEqual(stack.latestDeploymentError, "failed to deploy a stack: pull access denied for example/missing")
    }

    func testDecodesEnvironments() throws {
        let environments = try Fixture.decode([PortainerEnvironment].self, from: "endpoints")
        XCTAssertEqual(environments.map(\.id), [3, 5])
        XCTAssertEqual(environments.map(\.name), ["local", "nas"])
    }

    func testDecodesContainers() throws {
        let containers = try Fixture.decode([DockerContainer].self, from: "containers")
        XCTAssertEqual(containers.map(\.displayName), ["spike-test-web-1", "spike-test-worker-1"])
        XCTAssertEqual(StackHealth(containers: containers), StackHealth(running: 1, total: 2))
    }

    func testToleratesMinimalStack() throws {
        let json = Data(#"[{"Id": 1, "Name": "bare"}]"#.utf8)
        let stacks = try JSONDecoder().decode([Stack].self, from: json)
        XCTAssertEqual(stacks.first?.name, "bare")
        XCTAssertEqual(stacks.first?.kind, .unknown)
        XCTAssertFalse(stacks[0].canRedeploy)
    }
}

final class RedeployRequestTests: XCTestCase {
    private func json(_ request: RedeployRequest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testSendsCurrentBranchAndEnvBack() throws {
        let body = try json(RedeployRequest(stack: .sample(), repullImages: true, prune: false))
        XCTAssertEqual(body["RepositoryReferenceName"] as? String, "refs/heads/main")
        let env = try XCTUnwrap(body["Env"] as? [[String: String]])
        XCTAssertEqual(env, [["name": "TZ", "value": "Europe/Amsterdam"]])
        XCTAssertEqual(body["RepullImageAndRedeploy"] as? Bool, true)
        XCTAssertEqual(body["PullImage"] as? Bool, true)
        XCTAssertEqual(body["Prune"] as? Bool, false)
        XCTAssertEqual(body["RepositoryAuthentication"] as? Bool, false)
        XCTAssertNil(body["RepositoryUsername"])
        XCTAssertNil(body["RepositoryPassword"])
    }

    func testKeepsStoredGitCredentials() throws {
        let body = try json(RedeployRequest(stack: .sample(auth: true), repullImages: false, prune: true))
        XCTAssertEqual(body["RepositoryAuthentication"] as? Bool, true)
        XCTAssertEqual(body["RepositoryUsername"] as? String, "deploy")
        XCTAssertEqual(body["RepositoryPassword"] as? String, "", "an empty password keeps the stored one")
        XCTAssertEqual(body["RepositoryAuthorizationType"] as? Int, 0)
        XCTAssertEqual(body["RepullImageAndRedeploy"] as? Bool, false)
        XCTAssertEqual(body["Prune"] as? Bool, true)
    }

    func testSendsEmptyEnvArrayRatherThanNull() throws {
        var stack = Stack.sample()
        stack.env = nil
        let body = try json(RedeployRequest(stack: stack, repullImages: true, prune: false))
        XCTAssertEqual((body["Env"] as? [Any])?.count, 0)
    }
}

final class StackStatusTests: XCTestCase {
    func testHealthCountsStartingAndUnhealthy() {
        let health = StackHealth(containers: [
            .sample("a", status: "Up 5 seconds (health: starting)"),
            .sample("b", status: "Up 2 minutes (unhealthy)"),
            .sample("c", state: "exited", status: "Exited (1)"),
        ])
        XCTAssertEqual(health, StackHealth(running: 2, total: 3, starting: 1, unhealthy: 1))
        XCTAssertFalse(health.isHealthy)
    }

    func testDisplayStatus() {
        let stack = Stack.sample()
        XCTAssertEqual(StackDisplayStatus(stack: stack, health: StackHealth(running: 2, total: 2)), .running(2, 2))
        XCTAssertEqual(StackDisplayStatus(stack: stack, health: StackHealth(running: 1, total: 2)), .degraded(1, 2))
        XCTAssertEqual(StackDisplayStatus(stack: stack, health: StackHealth(running: 2, total: 2, unhealthy: 1)), .degraded(2, 2))
        XCTAssertEqual(StackDisplayStatus(stack: stack, health: StackHealth(running: 0, total: 2)), .stopped)
        XCTAssertEqual(StackDisplayStatus(stack: stack, health: StackHealth(running: 0, total: 0)), .stopped)
        XCTAssertEqual(StackDisplayStatus(stack: stack, health: nil), .unknown)
        XCTAssertEqual(StackDisplayStatus(stack: .sample(status: 3), health: StackHealth(running: 2, total: 2)), .deploying)
        XCTAssertEqual(StackDisplayStatus(stack: .sample(status: 4), health: StackHealth(running: 0, total: 1)), .failed)
    }
}
