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

struct ChallengeBanner: View {
    @EnvironmentObject var session: WebSession
    var body: some View {
        if session.needsChallenge {
            NavigationLink {
                LoginWebView(url: session.url("forum.php?forumlist=1&mobile=2"), title: "完成验证")
            } label: {
                HStack {
                    Image(systemName: "exclamationmark.shield")
                    Text("站点有验证码，点这里手动过")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .font(.footnote)
                .padding(10)
                .background(Color.orange.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal)
        }
    }
}
