import SwiftUI
import WebKit

struct RootView: View {
    @EnvironmentObject var session: WebSession
    @AppStorage("appearance.mode") private var appearanceMode = "system"
    private var selectedScheme: ColorScheme? {
        appearanceMode == "dark" ? .dark : (appearanceMode == "light" ? .light : nil)
    }

    var body: some View {
        TabView {
            NavigationStack {
                PortalView()
            }
            .tabItem { Label("首页", systemImage: "house.fill") }

            NavigationStack { ReadingLibraryView(isHistory: false) }
                .tabItem { Label("收藏", systemImage: "star") }

            NavigationStack { ReadingLibraryView(isHistory: true) }
                .tabItem { Label("历史", systemImage: "clock.arrow.circlepath") }

            NavigationStack { SearchView() }
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }

            NavigationStack {
                MineView()
            }
            .tabItem { Label("我的", systemImage: "person.crop.circle") }
        }
        .tint(ForumChrome.blue)
        .preferredColorScheme(selectedScheme)
        .background {
            HiddenWebView()
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
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
