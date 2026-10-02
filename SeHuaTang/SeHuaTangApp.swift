import SwiftUI

@main
struct SeHuaTangApp: App {
    @ObservedObject private var session = WebSession.shared
    @StateObject private var store = AppStore()

    init() { ExtractBackground.register() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .background { BackgroundKeepAlive() }
                .environmentObject(session)
                .environmentObject(store)
                .tint(SiteTheme.accent)
        }
    }
}
