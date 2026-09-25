import SwiftUI
import WebKit

struct RootView: View {
    @EnvironmentObject var session: WebSession

    var body: some View {
        TabView {
            NavigationStack {
                ForumHomeView()
            }
            .tabItem { Label("论坛", systemImage: "square.grid.2x2.fill") }

            NavigationStack {
                MineView()
            }
            .tabItem { Label("我的", systemImage: "person.crop.circle") }
        }
        .tint(ForumChrome.blue)
    }
}
