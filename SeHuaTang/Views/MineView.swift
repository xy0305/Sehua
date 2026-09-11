import SwiftUI

struct MineView: View {
    @EnvironmentObject var session: WebSession

    var body: some View {
        List {
            Section {
                NavigationLink {
                    LoginWebView(
                        url: session.url("member.php?mod=logging&action=login&mobile=2"),
                        title: "登录"
                    )
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(SiteTheme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.username ?? "未登录")
                                .font(.headline)
                            Text("验证码 / Cloudflare 在网页里手动过，过完点完成")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }

            Section("线路") {
                ForEach(SiteConfig.mirrors, id: \.self) { host in
                    Button {
                        session.host = host
                    } label: {
                        HStack {
                            Text(host)
                            Spacer()
                            if session.host == host {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(SiteTheme.accent)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }

            Section("网页") {
                NavigationLink("手机版首页") {
                    LoginWebView(url: session.url("portal.php?mod=index&mobile=2"), title: "首页")
                }
                NavigationLink("论坛板块") {
                    LoginWebView(url: session.url("forum.php?forumlist=1&mobile=2"), title: "论坛")
                }
            }

            Section {
                Button("清除 Cookie / 退出", role: .destructive) {
                    session.clearCookies()
                }
            }

            Section {
                Text("自用侧载。赌场 / 棋牌 / 鲍鱼盒子等广告在解析时丢弃。站点换域只改线路。详情解析不准时，用右上角 Safari 打开原网页。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("我的")
    }
}
