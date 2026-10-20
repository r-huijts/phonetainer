import Foundation
import Observation

@Observable @MainActor
final class StacksViewModel {
    enum LoadState: Equatable {
        case idle, loading, loaded, failed(String)
    }

    private(set) var rows: [StackRow] = []
    private(set) var state: LoadState = .idle
    private(set) var lastError: PortainerError?

    /// Loads the environment's stacks, then container state for each Compose stack in parallel.
    func load(client: PortainerClient, environmentId: Int) async {
        if rows.isEmpty { state = .loading }
        do {
            let stacks = try await client.stacks().filter { $0.endpointId == environmentId }
            let healthById = await withTaskGroup(of: (Int, StackHealth?).self, returning: [Int: StackHealth].self) { group in
                for stack in stacks where stack.kind == .compose {
                    group.addTask {
                        let containers = try? await client.containers(endpointId: environmentId, project: stack.name)
                        return (stack.id, containers.map { StackHealth(containers: $0) })
                    }
                }
                var result: [Int: StackHealth] = [:]
                for await (id, health) in group {
                    if let health { result[id] = health }
                }
                return result
            }
            rows = stacks
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { StackRow(stack: $0, health: healthById[$0.id]) }
            state = .loaded
            lastError = nil
        } catch {
            let portainerError = error as? PortainerError ?? LivePortainerClient.mapTransportError(error)
            // Pull to refresh cancels the previous load; that's not a failure.
            if portainerError == .cancelled { return }
            lastError = portainerError
            state = .failed(portainerError.localizedDescription)
        }
    }

    func reset() {
        rows = []
        state = .idle
        lastError = nil
    }
}
