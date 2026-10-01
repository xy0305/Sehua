import SwiftUI

struct MineView: View {
    @EnvironmentObject var session: WebSession
    @AppStorage("appearance.mode") private var appearanceMode = "system"
    @State private var showsClearCookiesConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                accountCard
                section("外观", symbol: "paintpalette") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("主题", selection: $appearanceMode) {
                            Text("跟随系统").tag("system")
                            Text("浅色").tag("light")
                            Text("深色").tag("dark")
                        }
                        .pickerStyle(.segmented)
                        Text("选择应用的显示主题，跟随系统会自动切换。")
                            .font(.footnote)
                            .foregroundStyle(ForumChrome.secondary)
                    }
                }
                section("访问线路", symbol: "network") {
                    VStack(spacing: 0) {
                        ForEach(SiteConfig.mirrors, id: \.self) { host in
                            Button {
                                session.host = host
                            } label: {
                                HStack(spacing: 12) {
                                    Text(host)
                                        .font(.subheadline)
                                        .foregroundStyle(ForumChrome.text)
                                        .multilineTextAlignment(.leading)
                                    Spacer()
                                    if session.host == host {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(ForumChrome.accent)
                                    }
                                }
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityValue(session.host == host ? "已选择" : "未选择")
                        }
                    }
                }
                section("网页辅助", symbol: "globe") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("日常浏览请使用底部的首页、收藏、历史和搜索。以下保留原网页入口，仅用于辅助访问。")
                            .font(.footnote)
                            .foregroundStyle(ForumChrome.secondary)
                        NavigationLink {
                            LoginWebView(url: session.url("portal.php?mod=index&mobile=2"), title: "原网页首页")
                        } label: {
                            webRow("原网页首页")
                        }
                        Divider().overlay(ForumChrome.line)
                        NavigationLink {
                            LoginWebView(url: session.url("forum.php?forumlist=1&mobile=2"), title: "原网页论坛")
                        } label: {
                            webRow("原网页论坛板块")
                        }
                    }
                    .buttonStyle(.plain)
                }
                section("本地会话", symbol: "lock.shield") {
                    VStack(alignment: .leading, spacing: 12) {
                        Button(role: .destructive) {
                            showsClearCookiesConfirmation = true
                        } label: {
                            Label("清除本地 Cookie", systemImage: "trash")
                                .frame(minHeight: 44)
                        }
                        Text("仅清除本机保存的 Cookie，不等同于服务端退出登录；需要时可重新打开网页完成登录或验证。")
                            .font(.footnote)
                            .foregroundStyle(ForumChrome.secondary)
                    }
                }
                Text("原生页面用于浏览和阅读；如内容解析不完整，可从详情页打开原网页辅助查看。")
                    .font(.footnote)
                    .foregroundStyle(ForumChrome.secondary)
                    .padding(.horizontal, 4)
            }
            .padding(16)
        }
        .background(ForumChrome.page)
        .tint(ForumChrome.accent)
        .navigationTitle("我的")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(ForumChrome.bar, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .confirmationDialog("清除本地 Cookie？", isPresented: $showsClearCookiesConfirmation, titleVisibility: .visible) {
            Button("清除本地 Cookie", role: .destructive) { session.clearCookies() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这只会清除本机 Cookie，不会向服务端发起退出请求。之后可能需要重新登录或完成验证。")
        }
    }

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(ForumChrome.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text(session.username ?? "未登录")
                        .font(.title2.bold())
                        .foregroundStyle(ForumChrome.text)
                    Text("账户与站点验证")
                        .font(.subheadline)
                        .foregroundStyle(ForumChrome.secondary)
                }
            }
            Text("登录、验证码及 Cloudflare 验证需要在网页中手动完成。这是必要的验证入口，不是应用主界面；完成后点「完成」返回原生页面。")
                .font(.subheadline)
                .foregroundStyle(ForumChrome.secondary)
                .fixedSize(horizontal: false, vertical: true)
            NavigationLink {
                LoginWebView(
                    url: session.url("member.php?mod=logging&action=login&mobile=2"),
                    title: "登录 / 完成验证"
                )
            } label: {
                Label("网页登录 / 完成验证", systemImage: "checkmark.shield")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(ForumChrome.bar, in: RoundedRectangle(cornerRadius: 16))
    }

    private func section<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(ForumChrome.text)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(ForumChrome.bar, in: RoundedRectangle(cornerRadius: 16))
    }

    private func webRow(_ title: String) -> some View {
        HStack {
            Text(title).foregroundStyle(ForumChrome.text)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ForumChrome.accent)
        }
        .font(.subheadline)
        .frame(minHeight: 44)
    }
}
