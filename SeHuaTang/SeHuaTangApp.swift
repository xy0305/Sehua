import SwiftUI

@main
struct SeHuaTangApp: App {
    @ObservedObject private var session = WebSession.shared
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(store)
                .tint(SiteTheme.accent)
        }
    }
}
