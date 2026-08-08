import SwiftUI

@main
struct HealthWorkoutExportApp: App {
    @State private var syncSession = SyncSession.shared

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(syncSession)
        }
    }
}
