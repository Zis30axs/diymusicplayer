import SwiftUI

@main
struct SigmaWatchApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(model)
        }
    }
}
