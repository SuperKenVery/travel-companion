import SwiftUI

@main
struct TravelCompanionApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var core = TravelCore()

    var body: some Scene {
        WindowGroup {
            AppShell()
                .environment(core)
                .task {
                    await core.bootstrap()
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    Task {
                        await core.send(.setForeground(phase == .active))
                    }
                }
        }
    }
}
