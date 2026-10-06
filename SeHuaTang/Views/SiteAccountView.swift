import SwiftUI

/// Reads the authenticated WK session; no balance or authentication is persisted.
struct SiteAccountView: View {
    @EnvironmentObject private var session: WebSession
    let signing: Bool
    @State private var rows: [AccountRow] = []
    @State private var status = ""
    @State private var busy = false
    @State private var nextURL: URL?
    @State private var signResult: String?
    private var path: String { signing ? "plugin.php?id=dd_sign&mobile=2" : "home.php?mod=spacecp&ac=credit&showcredit=1&mobile=2" }
    var body: some View {
        List {
            Section {
                Text(status.isEmpty ? "正在读取站点…" : status)
                Button("刷新真实状态") { Task { await load() } }.disabled(busy)
                if busy { ProgressView() }
            }
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.title).font(.headline)
                    Text(row.value).textSelection(.enabled)
                }
            }
            if let nextURL {
                Button("加载下一页明细") { Task { await load(nextURL) } }.disabled(busy)
            }
            Section("必要验证 / 原页兜底") {
                if signing {
                    NavigationLink {
                        SignVerificationView(result: $signResult)
                    } label: { Label("打开验证码并原生签到", systemImage: "checkmark.shield") }
                } else {
                    NavigationLink {
                        LoginWebView(url: session.url(path), title: "积分原页 / 登录验证")
                    } label: { Label("打开积分原页", systemImage: "checkmark.shield") }
                }
                Text(signing ? "请在验证码页手动完成验证。页面检测到验证通过后，只调用一次原生签到接口；超时或结果未知不会自动重试。" : "仅只读实际余额及变更记录，不执行兑换、充值或购买。解析失败不表示余额为零。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(signing ? "每日签到" : "我的积分")
        .onChange(of: signResult) { _, value in
            guard let value else { return }
            status = value
            Task { await load() }
        }
        .task { await load() }
        .refreshable { await load() }
    }
    @MainActor private func load(_ page: URL? = nil) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let source = page ?? session.url(path)
        do {
            let html = try await session.fetchHTML(source.absoluteString, timeout: 15)
            try Task.checkCancellation()
            guard source.host == session.url(path).host else { return }
            guard !DiscuzParser.looksLikeChallenge(html) else {
                status = "需要登录或验证；保留已读取数据，请打开原页。"
                return
            }
            let result = SiteAccountParser.parse(html, signing: signing)
            guard !result.rows.isEmpty else {
                status = "未识别到账户结构；保留已读取数据，请打开原页验证。"
                return
            }
            rows = page == nil ? result.rows : rows + result.rows
            status = result.status
            nextURL = HTML.elements(in: html, tag: "a").compactMap { a -> URL? in
                guard !signing, HTML.stripTags(a).contains("下一页") || HTML.hasClass("nxt", in: a),
                      let href = HTML.attribute("href", in: a), let url = HTML.absURL(href, base: source),
                      url.host == source.host, url.path == source.path,
                      URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "ac" && $0.value == "credit" }) == true else { return nil }
                return url
            }.first
        } catch { status = "读取失败；已有数据保留，请刷新，不会发起任何写请求。" }
    }
}

