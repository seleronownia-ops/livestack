import SwiftUI

@main
struct LiveStackApp: App {
    @StateObject private var project = ProjectModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(project)
        }
    }
}
