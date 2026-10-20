import SwiftUI

/// A colored label. Always carries text, so status never depends on color alone.
struct StatusChip: View {
    enum Tone { case success, warning, danger, neutral }

    let text: String
    let tone: Tone
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            Text(text)
        }
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .foregroundStyle(foreground)
        .background(background, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private var foreground: Color {
        switch tone {
        case .success: return Theme.successText
        case .warning: return Theme.warningText
        case .danger: return Theme.dangerText
        case .neutral: return Theme.neutralText
        }
    }

    private var background: Color {
        switch tone {
        case .success: return Theme.successFill
        case .warning: return Theme.warningFill
        case .danger: return Theme.dangerFill
        case .neutral: return Theme.neutralFill
        }
    }
}

extension StatusChip {
    init(status: StackDisplayStatus) {
        switch status {
        case .running(let running, let total):
            self.init(text: "Running \(running)/\(total)", tone: .success, systemImage: "checkmark.circle.fill")
        case .degraded(let running, let total):
            self.init(text: "Degraded \(running)/\(total)", tone: .warning, systemImage: "exclamationmark.triangle.fill")
        case .stopped:
            self.init(text: "Stopped", tone: .danger, systemImage: "stop.circle.fill")
        case .deploying:
            self.init(text: "Deploying", tone: .warning, systemImage: "arrow.triangle.2.circlepath")
        case .failed:
            self.init(text: "Deploy failed", tone: .danger, systemImage: "xmark.octagon.fill")
        case .unknown:
            self.init(text: "Status unknown", tone: .neutral, systemImage: "questionmark.circle")
        }
    }
}

#Preview {
    VStack(alignment: .leading) {
        StatusChip(status: .running(2, 2))
        StatusChip(status: .degraded(3, 4))
        StatusChip(status: .stopped)
        StatusChip(status: .deploying)
        StatusChip(status: .unknown)
    }
    .padding()
}
