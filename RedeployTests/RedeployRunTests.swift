import XCTest
@testable import Redeploy

@MainActor
final class RedeployRunTests: XCTestCase {
    private let fast = RedeployRun.Options(pollInterval: .seconds(1), deployTimeout: .seconds(5), verifyTimeout: .seconds(3))
    private let noSleep: @Sendable (Duration) async throws -> Void = { _ in }

    private func makeClient(containers: [DockerContainer] = [.sample("web"), .sample("db")]) -> MockPortainerClient {
        MockPortainerClient(stacks: [.sample()], containersByProject: ["spike-test": containers])
    }

    func testSynchronousRedeploySucceeds() async {
        let client = makeClient()
        let run = RedeployRun(stack: .sample(), repullImages: true, prune: false)
        await run.execute(client: client, options: fast, sleep: noSleep)

        XCTAssertEqual(run.phase, .succeeded)
        XCTAssertEqual(run.message, "2 of 2 containers running · commit 4f2c9a1")
        XCTAssertEqual(client.redeployCalls.count, 1)
        XCTAssertEqual(client.redeployCalls.first?.repullImages, true)
        XCTAssertEqual(client.redeployCalls.first?.prune, false)
        XCTAssertNotNil(run.finishedAt)
        XCTAssertEqual(run.steps.map(\.state), [.done, .done, .done, .done])
    }

    func testPollsWhileNewerPortainerReportsDeploying() async {
        let client = makeClient()
        client.deployingPolls = 2
        let run = RedeployRun(stack: .sample(), repullImages: false, prune: true)
        await run.execute(client: client, options: fast, sleep: noSleep)
        XCTAssertEqual(run.phase, .succeeded)
    }

    func testReportsPortainerDeploymentError() async {
        let client = makeClient()
        client.deployingPolls = 1
        client.statusAfterDeploy = 4
        let run = RedeployRun(stack: .sample(), repullImages: true, prune: false)
        await run.execute(client: client, options: fast, sleep: noSleep)

        XCTAssertEqual(run.phase, .failed)
        XCTAssertEqual(run.failedPhase, .redeploying)
        XCTAssertEqual(run.message, "compose up failed: image not found")
        XCTAssertEqual(run.steps.map(\.state), [.done, .failed, .pending, .pending])
    }

    func testGivesUpWhenStillDeployingAfterTimeout() async {
        let client = makeClient()
        client.deployingPolls = 100
        let run = RedeployRun(stack: .sample(), repullImages: true, prune: false)
        await run.execute(client: client, options: fast, sleep: noSleep)

        XCTAssertEqual(run.phase, .failed)
        XCTAssertEqual(run.failedPhase, .redeploying)
        XCTAssertTrue(run.message?.contains("still deploying") ?? false)
    }

    func testFailsVerificationWhenContainersDontRun() async {
        let client = makeClient(containers: [.sample("web"), .sample("db", state: "exited", status: "Exited (1)")])
        let run = RedeployRun(stack: .sample(), repullImages: true, prune: false)
        await run.execute(client: client, options: fast, sleep: noSleep)

        XCTAssertEqual(run.phase, .failed)
        XCTAssertEqual(run.failedPhase, .verifying)
        XCTAssertEqual(run.message, "Only 1 of 2 containers are running.")
        XCTAssertEqual(run.health, StackHealth(running: 1, total: 2))
    }

    func testAcceptsHealthChecksStillStartingAfterTimeout() async {
        let client = makeClient(containers: [.sample("web", status: "Up 10 seconds (health: starting)")])
        let run = RedeployRun(stack: .sample(), repullImages: true, prune: false)
        await run.execute(client: client, options: fast, sleep: noSleep)

        XCTAssertEqual(run.phase, .succeeded)
        XCTAssertTrue(run.message?.contains("health checks still starting") ?? false)
    }

    func testUnauthorizedIsSurfaced() async {
        let client = makeClient()
        client.redeployError = .unauthorized
        let run = RedeployRun(stack: .sample(), repullImages: true, prune: false)
        await run.execute(client: client, options: fast, sleep: noSleep)

        XCTAssertEqual(run.phase, .failed)
        XCTAssertEqual(run.error, .unauthorized)
        XCTAssertEqual(run.message, PortainerError.unauthorized.localizedDescription)
    }

    func testTimeoutDuringRequestSaysRedeployMayStillRun() async {
        let client = makeClient()
        client.redeployError = .timeout
        let run = RedeployRun(stack: .sample(), repullImages: true, prune: false)
        await run.execute(client: client, options: fast, sleep: noSleep)

        XCTAssertEqual(run.phase, .failed)
        XCTAssertTrue(run.message?.contains("may still be running") ?? false)
    }

    func testRefusesNonGitStack() async {
        let client = MockPortainerClient(stacks: [.sample(git: false)])
        let run = RedeployRun(stack: .sample(git: false), repullImages: true, prune: false)
        await run.execute(client: client, options: fast, sleep: noSleep)

        XCTAssertEqual(run.phase, .failed)
        XCTAssertEqual(run.failedPhase, .starting)
        XCTAssertEqual(run.message, "Not Git-based")
        XCTAssertTrue(client.redeployCalls.isEmpty)
    }

    func testUnreachableServer() async {
        let client = makeClient()
        client.error = .unreachable("Could not connect to the server.")
        let run = RedeployRun(stack: .sample(), repullImages: true, prune: false)
        await run.execute(client: client, options: fast, sleep: noSleep)

        XCTAssertEqual(run.phase, .failed)
        XCTAssertEqual(run.failedPhase, .starting)
        XCTAssertTrue(run.message?.contains("Can't reach the server") ?? false)
    }
}
