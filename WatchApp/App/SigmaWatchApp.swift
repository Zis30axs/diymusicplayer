import SwiftUI

@main
struct SigmaWatchApp: App {
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(model)
        }
        .backgroundTask(.urlSession(AppModel.downloadSessionId)) { _ in
            await AppModel.shared.finishBackgroundDownloads()
        }
    }
}
