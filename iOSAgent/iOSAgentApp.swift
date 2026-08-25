import SwiftUI

@main
struct iOSAgentApp: App {
    @StateObject private var store = ChatStore.shared
    @StateObject private var settings = SettingsStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(settings)
        }
    }
}
