import SwiftUI

@main @MainActor struct SekaiApp: App {
    @StateObject private var root = AppCompositionRoot()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(root: root)
                .onChange(of: scenePhase) { phase in
                    if phase == .active { root.foreground() }
                }
        }
    }
}
