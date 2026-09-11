import SwiftUI
import WebKit

struct RootView: View {
    @EnvironmentObject var session: WebSession
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { ForumHomeView() }
                .tabItem { Label("论坛", systemImage: "square.grid.2x2.fill") }
                .tag(0)
            NavigationStack { SearchView() }
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                .tag(1)
            NavigationStack { MineView() }
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
                .tag(2)
        }
        .background {
            HiddenWebView().frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
        }
    }
}

struct HiddenWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { WebSession.shared.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
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
                    Text("站点有验证码 / Cloudflare，点这里手动过")
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
