import Foundation
import Observation

/// One redeploy, from the request to verified containers.
///
/// Portainer gives no per-step progress, so the phases are the honest ones:
/// starting → redeploying (request in flight, or Portainer reports "deploying")
/// → verifying (polling container state) → succeeded or failed.
@Observable @MainActor
final class RedeployRun: Identifiable {
    enum Phase: Equatable {
        case starting, redeploying, verifying, succeeded, failed
    }

    struct Options: Sendable {
        var pollInterval: Duration = .seconds(3)
        var deployTimeout: Duration = .seconds(15 * 60)
        var verifyTimeout: Duration = .seconds(90)
    }

    struct Step: Identifiable, Equatable {
        enum State: Equatable { case pending, active, done, failed }
        let id: Int
        let title: String
        let detail: String
        let state: State
    }

    nonisolated let id = UUID()
    let stack: Stack
    let repullImages: Bool
    let prune: Bool
    let startedAt = Date()

    private(set) var phase: Phase = .starting
    private(set) var failedPhase: Phase?
    private(set) var message: String?
    private(set) var error: PortainerError?
    private(set) var health: StackHealth?
    private(set) var finishedAt: Date?

    init(stack: Stack, repullImages: Bool, prune: Bool) {
        self.stack = stack
        self.repullImages = repullImages
        self.prune = prune
    }

    var isFinished: Bool { phase == .succeeded || phase == .failed }
    var succeeded: Bool { phase == .succeeded }
    var duration: TimeInterval { (finishedAt ?? Date()).timeIntervalSince(startedAt) }

    var steps: [Step] {
        let items: [(title: String, detail: String)] = [
            ("Starting", "Reading the stack's current settings"),
            ("Redeploying", repullImages
                ? "Portainer pulls from Git, re-pulls images and recreates changed containers"
                : "Portainer pulls from Git and recreates changed containers"),
            ("Verifying", "Waiting for the containers to run"),
            ("Done", "The stack is up to date"),
        ]
        let order: [Phase] = [.starting, .redeploying, .verifying, .succeeded]
        let reached = phase == .failed ? (failedPhase ?? .starting) : phase
        let current = order.firstIndex(of: reached) ?? 0
        return items.enumerated().map { pair -> Step in
            let state: Step.State
            if phase == .succeeded || pair.offset < current {
                state = .done
            } else if pair.offset == current {
                state = phase == .failed ? .failed : .active
            } else {
                state = .pending
            }
            return Step(id: pair.offset, title: pair.element.title, detail: pair.element.detail, state: state)
        }
    }

    func execute(
        client: PortainerClient,
        options: Options = Options(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async {
        let deployPolls = max(1, Int((options.deployTimeout / options.pollInterval).rounded(.up)))
        let verifyPolls = max(1, Int((options.verifyTimeout / options.pollInterval).rounded(.up)))
        do {
            // Fetch fresh: the redeploy body must carry the stack's current env vars and branch.
            let fresh = try await client.stack(id: stack.id)
            guard fresh.canRedeploy, let endpointId = fresh.endpointId else {
                return fail(fresh.unavailableReason ?? "This stack can't be redeployed.")
            }

            phase = .redeploying
            var current = try await client.redeploy(stack: fresh, repullImages: repullImages, prune: prune)
            var polls = 0
            while current.lifecycle == .deploying {
                if polls >= deployPolls {
                    return fail("Portainer is still deploying after \(Self.minutes(options.deployTimeout)). Check the stack in Portainer.")
                }
                polls += 1
                try await sleep(options.pollInterval)
                current = try await client.stack(id: stack.id)
            }
            if current.lifecycle == .error {
                return fail(current.latestDeploymentError ?? "Portainer reported that the deployment failed.")
            }

            phase = .verifying
            polls = 0
            while true {
                let containers = try await client.containers(endpointId: endpointId, project: current.name)
                let health = StackHealth(containers: containers)
                self.health = health
                if health.isHealthy {
                    return succeed(health: health, stack: current, note: nil)
                }
                if polls >= verifyPolls {
                    if health.allRunning && health.unhealthy == 0 {
                        return succeed(health: health, stack: current, note: "health checks still starting")
                    }
                    return fail(health.failureDescription)
                }
                polls += 1
                try await sleep(options.pollInterval)
            }
        } catch {
            fail(error: error)
        }
    }

    /// Ends the run without contacting the server, e.g. when the app isn't configured.
    func fail(error: Error) {
        var portainerError = error as? PortainerError
        if portainerError == nil, error is CancellationError {
            portainerError = .cancelled
        }
        self.error = portainerError
        // A dropped connection during the request doesn't mean the redeploy stopped on the server.
        if phase == .redeploying, portainerError == .timeout {
            return fail("Portainer didn't answer in time. The redeploy may still be running; check the stack in Portainer.")
        }
        if phase == .redeploying, case .unreachable(_)? = portainerError {
            return fail("The connection dropped during the redeploy. It may still be running on the server; check the stack in Portainer.")
        }
        fail(portainerError?.localizedDescription ?? error.localizedDescription)
    }

    private func fail(_ text: String) {
        failedPhase = phase
        phase = .failed
        message = text
        finishedAt = Date()
    }

    private func succeed(health: StackHealth, stack: Stack, note: String?) {
        var parts = ["\(health.running) of \(health.total) containers running"]
        if let note { parts.append(note) }
        if let commit = stack.shortCommit { parts.append("commit \(commit)") }
        phase = .succeeded
        message = parts.joined(separator: " · ")
        finishedAt = Date()
    }

    private static func minutes(_ duration: Duration) -> String {
        let minutes = Int(duration.components.seconds / 60)
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}
