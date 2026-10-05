import SwiftUI
import KSPlayer

/// Library errors may include signed URLs and request headers. Discard them, not redact guesses.
private struct SilentPlaybackLog: LogHandler {
    func log(level: LogLevel, message: CustomStringConvertible, file: String, function: String, line: UInt) {}
}

@main
struct SeHuaTangApp: App {
    @ObservedObject private var session = WebSession.shared
    @StateObject private var store = AppStore()

    init() {
        KSOptions.logger = SilentPlaybackLog()
        ExtractBackground.register()
    }

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
