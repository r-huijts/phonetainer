import SwiftUI

struct ConfirmSheet: View {
    let stack: Stack
    let onStarted: (RedeployRun) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var repullImages = true
    @State private var prune = false
    @State private var isAuthenticating = false
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Redeploy stack")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                    Text(stack.name)
                        .font(.title2.bold())
                        .foregroundStyle(Theme.text)
                }

                VStack(alignment: .leading, spacing: 10) {
                    summaryLine("arrow.down.circle", "Pull the latest commit from \(stack.branch ?? "the stack's branch")")
                    summaryLine("shippingbox", repullImages
                        ? "Re-pull every image, even if its tag hasn't changed"
                        : "Use the images already on the host")
                    summaryLine("arrow.triangle.2.circlepath", "Recreate the containers that changed")
                }

                VStack(spacing: 0) {
                    Toggle("Re-pull images", isOn: $repullImages)
                        .frame(minHeight: Theme.minTouchHeight)
                    Divider()
                    Toggle(isOn: $prune) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Prune unused resources")
                            Text("Remove services no longer in the compose file")
                                .font(.footnote)
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .frame(minHeight: Theme.minTouchHeight)
                    .padding(.vertical, 6)
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.vertical, 4)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))

                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Theme.dangerText)
                }

                VStack(spacing: 12) {
                    Button {
                        Task { await confirm() }
                    } label: {
                        Label(confirmTitle, systemImage: confirmSymbol)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isAuthenticating || appState.activeRun != nil)

                    Button("Cancel", role: .cancel) { dismiss() }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(20)
        }
        .presentationDetents([.fraction(0.75), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Theme.sheetRadius)
        .presentationBackground(Theme.surface)
        .onAppear { repullImages = appState.settings.repullImagesByDefault }
    }

    private var confirmTitle: String {
        appState.settings.requireAuthentication
            ? "Redeploy with \(DeviceAuthentication.methodName)"
            : "Redeploy"
    }

    private var confirmSymbol: String {
        appState.settings.requireAuthentication ? DeviceAuthentication.symbolName : "arrow.clockwise"
    }

    private func summaryLine(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).foregroundStyle(Theme.text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Theme.accent)
        }
        .font(.subheadline)
    }

    private func confirm() async {
        errorText = nil
        if appState.settings.requireAuthentication {
            isAuthenticating = true
            do {
                try await DeviceAuthentication.authenticate(reason: "Redeploy \(stack.name)")
                isAuthenticating = false
            } catch {
                isAuthenticating = false
                if !DeviceAuthentication.isCancellation(error) {
                    errorText = error.localizedDescription
                }
                return
            }
        }
        if let run = appState.startRedeploy(stack, repullImages: repullImages, prune: prune) {
            onStarted(run)
        } else {
            errorText = "Another redeploy is still running."
        }
    }
}

#Preview {
    Text("Stacks")
        .sheet(isPresented: .constant(true)) {
            ConfirmSheet(stack: MockPortainerClient.demo().stackList[0]) { _ in }
                .environment(AppState.demo())
        }
}
