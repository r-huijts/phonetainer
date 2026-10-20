import SwiftUI

struct ActivityView: View {
    @Environment(AppState.self) private var appState
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Group {
                if appState.activity.entries.isEmpty {
                    ContentUnavailableView(
                        "No redeploys yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Redeploys you start from this app show up here.")
                    )
                } else {
                    List(appState.activity.entries) { entry in
                        ActivityRow(entry: entry)
                            .listRowBackground(Theme.surface)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
            .navigationTitle("Activity")
            .toolbar {
                if !appState.activity.entries.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear") { confirmClear = true }
                    }
                }
            }
            .confirmationDialog("Clear the redeploy history?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear history", role: .destructive) { appState.activity.clear() }
            }
            .toolbarBackground(Theme.surface, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
        }
    }
}

private struct ActivityRow: View {
    let entry: ActivityEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.stackName)
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                if entry.succeeded {
                    StatusChip(text: "Succeeded", tone: .success, systemImage: "checkmark.circle.fill")
                } else {
                    StatusChip(text: "Failed", tone: .danger, systemImage: "xmark.octagon.fill")
                }
            }
            if !entry.message.isEmpty {
                Text(entry.message)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
            Text("\(when) · took \(took)")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var when: String { entry.date.formatted(.relative(presentation: .named)) }
    private var took: String { Duration.seconds(entry.duration.rounded()).formatted(.time(pattern: .minuteSecond)) }
}

#Preview {
    ActivityView().environment(AppState.demo())
}
