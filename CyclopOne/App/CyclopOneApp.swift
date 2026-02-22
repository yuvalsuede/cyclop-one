import SwiftUI

@main
struct CyclopOneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Empty scene — we manage windows manually via AppDelegate
        Settings {
            SettingsView()
                .environmentObject(appDelegate.agentCoordinator)
        }
    }
}
