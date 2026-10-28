import SwiftUI

struct RedeployProgressView: View {
    let run: RedeployRun
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                statusBlock

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(run.steps) { step in
                        StepRow(step: step)
                        if step.id < run.steps.count - 1 {
                            Divider().padding(.leading, 36)
                        }
                    }
                }
                .card()

                if let message = run.message {
                    resultMessage(message)
                }

                if run.isFinished {
                    Button("Done") { dismiss() }
                        .buttonStyle(PrimaryButtonStyle())
                } else {
                    Button("Run in background") { dismiss() }
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityHint("The redeploy continues and you'll be notified when it finishes")
                }
            }
            .padding(20)
        }
        .background(Theme.background)
        .presentationDetents([.large])
        .presentationCornerRadius(Theme.sheetRadius)
        .presentationBackground(Theme.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headerTitle)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
            Text(run.stack.name)
                .font(.title2.bold())
                .foregroundStyle(Theme.text)
        }
        .accessibilityElement(children: .combine)
    }

    private var headerTitle: String {
        switch run.phase {
        case .succeeded: return "Redeployed"
        case .failed: return "Redeploy failed"
        default: return "Redeploying"
        }
    }

    private var statusBlock: some View {
        HStack(spacing: 12) {
            switch run.phase {
            case .succeeded:
                Image(systemName: "checkmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(Theme.successText)
                    .accessibilityHidden(true)
            case .failed:
                Image(systemName: "xmark.octagon.fill")
                    .font(.title)
                    .foregroundStyle(Theme.dangerText)
                    .accessibilityHidden(true)
            default:
                ProgressView()
                    .controlSize(.large)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(phaseText)
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                elapsed
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var elapsed: some View {
        if let finishedAt = run.finishedAt {
            Text("Took \(Self.format(finishedAt.timeIntervalSince(run.startedAt)))")
        } else {
            TimelineView(.periodic(from: run.startedAt, by: 1)) { context in
                Text("Elapsed \(Self.format(context.date.timeIntervalSince(run.startedAt)))")
            }
        }
    }

    private var phaseText: String {
        switch run.phase {
        case .starting: return "Starting"
        case .redeploying: return "Waiting for Portainer"
        case .verifying: return "Checking containers"
        case .succeeded: return "Stack is running"
        case .failed: return "Something went wrong"
        }
    }

    private func resultMessage(_ message: String) -> some View {
        let failed = run.phase == .failed
        return Label(message, systemImage: failed ? "exclamationmark.triangle.fill" : "info.circle.fill")
            .font(.subheadline)
            .foregroundStyle(failed ? Theme.dangerText : Theme.successText)
            .padding(Theme.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(failed ? Theme.dangerFill : Theme.successFill,
                        in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
    }

    private static func format(_ interval: TimeInterval) -> String {
        Duration.seconds(max(0, interval.rounded())).formatted(.time(pattern: .minuteSecond))
    }
}

private struct StepRow: View {
    let step: RedeployRun.Step

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.body.weight(step.state == .active ? .semibold : .regular))
                    .foregroundStyle(step.state == .pending ? Theme.secondaryText : Theme.text)
                Text(step.detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityValue(stateLabel)
    }

    @ViewBuilder
    private var icon: some View {
        switch step.state {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.successText)
        case .active:
            ProgressView()
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.dangerText)
        case .pending:
            Image(systemName: "circle").foregroundStyle(Theme.borderStrong)
        }
    }

    private var stateLabel: String {
        switch step.state {
        case .done: return "Done"
        case .active: return "In progress"
        case .failed: return "Failed"
        case .pending: return "Not started"
        }
    }
}

#Preview {
    let run = RedeployRun(stack: MockPortainerClient.demo().stackList[0], repullImages: true, prune: false)
    return RedeployProgressView(run: run)
        .task { await run.execute(client: MockPortainerClient.demo()) }
}
