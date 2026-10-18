import SwiftUI

@main
struct ScreenMirrorApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.didBecomeActive() }
        }
    }
}
