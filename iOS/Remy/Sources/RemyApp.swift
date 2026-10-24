import SwiftUI

@main struct RemyApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase
    init() {
        // Sheet and list titles in Google Sans Flex, matching the rest of the app.
        let bar = UINavigationBar.appearance()
        if let title = UIFont(name: "GoogleSansFlex-Medium", size: 17) { bar.titleTextAttributes = [.font: title] }
        if let large = UIFont(name: "GoogleSansFlex-Regular", size: 32) { bar.largeTitleTextAttributes = [.font: large] }
    }
    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .preferredColorScheme(.dark)
                .task {
                    UIApplication.shared.isIdleTimerDisabled = true
                    // Hands-free means no setup tap: once the downloaded model is verified, load it, which also
                    // turns the microphone on.
                    for _ in 0..<600 where model.models.isWorking { try? await Task.sleep(for: .milliseconds(200)) }
                    if model.models.modelURL != nil, !model.isLoaded, !model.isLoading { await model.loadModel() }
                }
                .onChange(of: phase) { _, value in
                    if value == .active { UIApplication.shared.isIdleTimerDisabled = true }
                    if value == .background { UIApplication.shared.isIdleTimerDisabled = false }
                    // Permission sheets temporarily make the scene inactive. Only leaving the app pauses capture.
                    model.sceneChanged(value)
                }
        }
    }
}
