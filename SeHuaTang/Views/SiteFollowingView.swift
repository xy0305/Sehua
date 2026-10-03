import SwiftUI

/// Site collections are read-only here; mutations stay in explicitly opened site forms.
struct SiteFollowingView: View {
    @EnvironmentObject private var session: WebSession
    @State private var section = 0
    @State private var entries: [SiteEntry] = []
    @State private var nextURL: URL?
    @State private var busy = false
    @State private var status = ""
    private struct SiteEntry: Identifiable { let id: Int; let title: String }
    private var path: String {
        section == 0 ? "home.php?mod=space&do=favorite&type=thread&mobile=2" : "home.php?mod=space&do=follow&view=following&mobile=2"
    }
    var body: some View {
        VStack(spacing: 12) {
            Picker("站点内容", selection: $section) {
                Text("站点收藏").tag(0)
                Text("关注用户").tag(1)
            }.pickerStyle(.segmented).padding(.horizontal)
            NavigationLink {
                LoginWebView(url: session.url(path), title: section == 0 ? "站点收藏" : "关注用户")
            } label: { Label("打开站点原页 / 登录验证", systemImage: "globe") }
            if !status.isEmpty { Text(status).font(.footnote).foregroundStyle(.secondary).padding(.horizontal) }
            List(entries) { entry in
                if section == 0 {
                    NavigationLink(entry.title) { ThreadDetailView(tid: entry.id, title: entry.title) }
                } else {
                    NavigationLink(entry.title) { MemberSpaceView(uid: entry.id, name: entry.title) }
                }
            }.listStyle(.plain)
            HStack {
                Button("重新加载") { Task { await load(reset: true) } }
                if nextURL != nil { Button("加载下一页") { Task { await load(reset: false) } } }
                if busy { ProgressView() }
            }.disabled(busy).padding(.bottom)
        }
        .background(ForumChrome.page)
        .navigationTitle("关注")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: section) { await load(reset: true) }
    }
    @MainActor private func load(reset: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        if reset { entries = []; nextURL = nil }
        let selected = section
        let url = reset ? session.url(path) : (nextURL ?? session.url(path))
        do {
            let html = try await session.fetchHTML(url.absoluteString, timeout: 15)
            guard section == selected else { return }
            let links = HTML.elements(in: html, tag: "a")
            // Restrict native records to list rows, never global headers/account navigation.
            let containers = HTML.elements(in: html, tag: "li") + HTML.elements(in: html, tag: "tr")
            let rows = containers.flatMap { HTML.elements(in: $0, tag: "a") }
            var seen = Set(entries.map(\.id))
            for anchor in rows {
                guard let href = HTML.attribute("href", in: anchor) else { continue }
                let title = HTML.stripTags(anchor)
                guard !title.isEmpty else { continue }
                let id = selected == 0 ? HTML.queryInt("tid", in: href) : HTML.queryInt("uid", in: href)
                guard let id, id > 0, seen.insert(id).inserted else { continue }
                if selected == 1 && !href.contains("mod=space") { continue }
                entries.append(SiteEntry(id: id, title: title))
            }
            nextURL = links.compactMap { anchor -> URL? in
                let text = HTML.stripTags(anchor)
                guard text.contains("下一页") || HTML.attribute("class", in: anchor)?.split(separator: " ").contains("nxt") == true,
                      let href = HTML.attribute("href", in: anchor), let candidate = HTML.absURL(href, base: url),
                      candidate.host == url.host, candidate.path == url.path,
                      candidate.query?.contains(selected == 0 ? "do=favorite" : "do=follow") == true else { return nil }
                return candidate
            }.first
            status = entries.isEmpty ? "未识别到站点列表。请打开原页确认登录、验证或页面结构；不代表收藏/关注为空。" : "来自站点登录会话；点击主题或用户打开原生页面。"
        } catch { status = "读取失败，请重试或打开站点原页完成登录验证。" }
    }
}
