import SwiftUI

@main
struct RedeployApp: App {
    @State private var appState = ProcessInfo.processInfo.arguments.contains("--demo") ? AppState.demo() : AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .tint(Theme.accent)
                .preferredColorScheme(.light)
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        TabView(selection: $appState.selectedTab) {
            StacksView()
                .tabItem { Label("Stacks", systemImage: "square.stack.3d.up") }
                .tag(AppState.Tab.stacks)
            ActivityView()
                .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }
                .tag(AppState.Tab.activity)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppState.Tab.settings)
        }
    }
}

#Preview {
    RootView().environment(AppState.demo())
}
