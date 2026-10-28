import SwiftUI

struct StackRow: Identifiable, Equatable {
    let stack: Stack
    let health: StackHealth?

    var id: Int { stack.id }
    var status: StackDisplayStatus { StackDisplayStatus(stack: stack, health: health) }
}

struct StackCard: View {
    let row: StackRow
    /// This stack is being redeployed right now.
    let isRedeploying: Bool
    /// Another stack is being redeployed; only one at a time.
    let isBlocked: Bool
    let onRedeploy: () -> Void
    let onShowProgress: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.stack.name)
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                StatusChip(status: row.status)
            }

            VStack(alignment: .leading, spacing: 4) {
                if let branch = row.stack.branch {
                    Label {
                        Text(row.stack.shortCommit.map { "\(branch) · \($0)" } ?? branch)
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "arrow.triangle.branch")
                    }
                    .accessibilityLabel(branchAccessibilityLabel(branch))
                }
                if let updatedAt = row.stack.updatedAt {
                    Label {
                        Text("Redeployed \(updatedAt, format: .relative(presentation: .named))")
                    } icon: {
                        Image(systemName: "clock")
                    }
                }
            }
            .font(.footnote)
            .foregroundStyle(Theme.secondaryText)

            actionButton
        }
        .card()
    }

    @ViewBuilder
    private var actionButton: some View {
        if let reason = row.stack.unavailableReason {
            Button {} label: {
                Text(reason)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(true)
        } else if isRedeploying {
            Button(action: onShowProgress) {
                Label("Redeploying… View progress", systemImage: "hourglass")
            }
            .buttonStyle(SecondaryButtonStyle())
        } else {
            Button(action: onRedeploy) {
                Label("Pull & redeploy", systemImage: "arrow.clockwise")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isBlocked)
            .accessibilityHint("Asks for confirmation first")
        }
    }

    private func branchAccessibilityLabel(_ branch: String) -> String {
        if let commit = row.stack.shortCommit {
            return "Branch \(branch), commit \(commit)"
        }
        return "Branch \(branch)"
    }
}
