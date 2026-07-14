import SwiftUI

@main
struct TravelCompanionApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var coordinator = ExperimentCoordinator()

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            DiagnosticsRootView(coordinator: coordinator)
                .task { await coordinator.restoreIfNeeded() }
                .onChange(of: scenePhase) { _, phase in
                    coordinator.setForeground(phase == .active)
                }
            #else
            ContentUnavailableView(
                "仅用于 Debug 技术验证",
                systemImage: "hammer",
                description: Text("第 11 节诊断页面不会出现在 Release 构建。")
            )
            #endif
        }
    }
}
