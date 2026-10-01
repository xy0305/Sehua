import SwiftUI
import UIKit

struct ThreadDetailView: View {
    let tid: Int
    let title: String
    @EnvironmentObject var session: WebSession
    @EnvironmentObject var store: AppStore
    @ObservedObject private var library = ReadingLibrary.shared
    @State private var detail: ThreadDetail?
    @State private var state: LoadState = .idle
    @State private var copied = false
    @State private var copiedAttachmentID: String?

    var body: some View {
        VStack(spacing: 0) {
            ForumTopBar(title: detail?.boardName.isEmpty == false ? (detail?.boardName ?? "帖子") : "帖子")
            detailToolbar
            Group {
                if state == .loading && detail == nil {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = state.errorMessage, detail == nil {
                    ContentUnavailableView {
                        Label("加载失败", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("重试") { Task { await load() } }
                    }
                } else if let detail {
                    content(detail)
                }
            }
            .background(ForumChrome.page)
        }
        .background(ForumChrome.page)
        .tint(ForumChrome.blue)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            library.record(readingItem)
            await load()
        }
    }

    // The app uses a custom top bar and hides UINavigationBar; keep this native
    // toolbar visible rather than attaching items to the hidden system bar.
    private var detailToolbar: some View {
        HStack {
            Text("主题正文")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ForumChrome.secondary)
            Spacer()
            Button {
                library.toggleFavorite(readingItem)
            } label: {
                Label(library.isFavorite(tid) ? "已收藏 · 本机" : "收藏到本机",
                      systemImage: library.isFavorite(tid) ? "star.fill" : "star")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ForumChrome.blue)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .background(ForumChrome.bar)
        .overlay(alignment: .bottom) { ForumChrome.line.frame(height: 0.5) }
    }

    private var readingItem: ThreadItem {
        var item = store.threads.first(where: { $0.id == tid }) ?? ThreadItem(
            id: tid, title: title, excerpt: "", author: "", authorID: nil,
            avatarURL: nil, coverURL: nil, dateText: "", replies: "",
            likes: "", views: "", isSticky: false, fid: nil
        )
        if let detail {
            if !detail.title.isEmpty { item.title = detail.title }
            item.fid = detail.fid ?? item.fid
            if !detail.replyCount.isEmpty { item.replies = detail.replyCount }
            if let post = detail.posts.first {
                item.author = post.author
                item.authorID = post.authorID
                item.avatarURL = post.avatarURL
                item.dateText = post.dateText
                item.coverURL = post.images.first ?? detail.images.first ?? item.coverURL
                item.excerpt = String(cleaned(post.plainText).prefix(160))
            }
        }
        return item
    }

    private func content(_ d: ThreadDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let error = state.errorMessage {
                    HStack {
                        Text(error).font(.footnote).foregroundStyle(ForumChrome.secondary)
                        Spacer()
                        Button("重试") { Task { await load() } }
                            .font(.footnote)
                    }
                    .padding(16)
                    .background(ForumChrome.page)
                }
                Text(d.title.isEmpty ? title : d.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(ForumChrome.text)
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 16)

                NavigationLink {
                    Pan115ResourceView(detail: d, base: session.baseURL)
                } label: {
                    Label("115 归档 / 播放", systemImage: "externaldrive.badge.plus")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)

                if let post = d.posts.first {
                    authorBar(post)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }

                if !d.magnets.isEmpty || !d.attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("下载").font(.system(size: 15, weight: .semibold))
                        ForEach(d.magnets + d.attachments) { m in
                            HStack {
                                Image(systemName: m.isMagnet ? "link" : "arrow.down.doc")
                                    .foregroundStyle(ForumChrome.blue)
                                Text(m.isMagnet ? "磁力链接" : (m.isED2K ? "eD2k" : m.name)).lineLimit(1)
                                Spacer()
                                Button(copiedAttachmentID == m.id ? "已复制" : "复制") {
                                    UIPasteboard.general.string = m.url.absoluteString
                                    copiedAttachmentID = m.id
                                }
                                .font(.system(size: 13, weight: .semibold))
                                if !m.isMagnet && !m.isED2K && (m.name.lowercased().hasSuffix(".txt") || m.url.pathExtension.lowercased() == "txt") {
                                    NavigationLink("阅读") { TextAttachmentView(attachment: m) }
                                        .font(.system(size: 13, weight: .semibold))
                                } else {
                                    Button("打开") { SiteLinks.open(m.url) }
                                        .font(.system(size: 13, weight: .semibold))
                                }
                            }
                            .font(.system(size: 14))
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ForumChrome.page)
                    .overlay(alignment: .bottom) { ForumChrome.line.frame(height: 0.5) }
                }

                if let body = d.posts.first?.htmlBody, !SiteLinks.links(in: body, base: session.baseURL).isEmpty {
                    let links = SiteLinks.links(in: body, base: session.baseURL)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("链接").font(.system(size: 15, weight: .semibold))
                        ForEach(links, id: \.absoluteString) { url in
                            Button {
                                SiteLinks.open(url)
                            } label: {
                                HStack {
                                    Image(systemName: SiteLinks.staysInApp(url) ? "doc.text" : "safari")
                                    Text(url.host ?? url.absoluteString).lineLimit(1)
                                    Spacer()
                                    Text(SiteLinks.staysInApp(url) ? "打开" : "浏览器")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .font(.system(size: 14))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ForumChrome.page)
                    .overlay(alignment: .bottom) { ForumChrome.line.frame(height: 0.5) }
                }

                ForEach(d.posts) { post in
                    VStack(alignment: .leading, spacing: 10) {
                        if d.posts.first?.id != post.id {
                            authorBar(post, isOriginal: false)
                        }
                        let text = cleaned(post.plainText)
                        if !text.isEmpty {
                            Text(text)
                                .font(.system(size: 16))
                                .foregroundStyle(ForumChrome.text)
                                .lineSpacing(6)
                                .textSelection(.enabled)
                        }
                        if !post.images.isEmpty {
                            imageStrip(post.images)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ForumChrome.bar)
                    .overlay(alignment: .bottom) { ForumChrome.line.frame(height: 0.5) }
                }

                if d.posts.allSatisfy(\.images.isEmpty), !d.images.isEmpty {
                    imageStrip(d.images)
                        .padding(16)
                }
                Text("当前显示已加载的正文与回复；发表回复及站点收藏使用网页表单。")
                    .font(.caption)
                    .foregroundStyle(ForumChrome.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ForumChrome.page)
            }
            .background(ForumChrome.bar)
            .padding(.bottom, 24)
        }
        .refreshable { await load() }
        .safeAreaInset(edge: .bottom) {
            actionBar(d)
        }
    }

    private func actionBar(_ d: ThreadDetail) -> some View {
        HStack(spacing: 12) {
            if let url = d.replyURL {
                NavigationLink {
                    LoginWebView(url: url, title: "回复 · 网页表单")
                } label: {
                    Label("网页回复", systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
            }
            if let url = d.favoriteURL {
                NavigationLink {
                    LoginWebView(url: url, title: "站点收藏 · 网页表单")
                } label: {
                    Label("站点收藏", systemImage: "safari")
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
            }
            Button {
                UIPasteboard.general.string = session.url("forum.php?mod=viewthread&tid=\(d.tid)&mobile=2").absoluteString
                copied = true
            } label: {
                Label(copied ? "已复制" : "链接", systemImage: "link")
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
        }
        .font(.system(size: 15, weight: .semibold))
        .buttonStyle(.bordered)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private func authorBar(_ post: ThreadPost, isOriginal: Bool = true) -> some View {
        HStack(spacing: 10) {
            avatar(post.avatarURL)
            VStack(alignment: .leading, spacing: 3) {
                Text(post.author.isEmpty ? "楼主" : post.author)
                    .font(.system(size: 15, weight: .semibold))
                if !post.dateText.isEmpty {
                    Text(post.dateText)
                        .font(.system(size: 12))
                        .foregroundStyle(ForumChrome.secondary)
                }
            }
            Spacer()
            Text(isOriginal ? "楼主" : "回复")
                .font(.system(size: 12))
                .foregroundStyle(ForumChrome.blue)
        }
    }

    private func avatar(_ url: URL?) -> some View {
        Group {
            if let url {
                SiteImage(url: url) {
                    ForumChrome.page
                }
            } else {
                Image(systemName: "person.fill")
                    .foregroundStyle(ForumChrome.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ForumChrome.page)
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(Circle())
    }

    private func imageStrip(_ urls: [URL]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(urls, id: \.self) { url in
                    NavigationLink {
                        ImagePage(url: url)
                    } label: {
                        SiteImage(url: url) {
                            ForumChrome.page
                        }
                        .frame(width: 160, height: 210)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func cleaned(_ s: String) -> String {
        var t = s
        for k in SiteConfig.adKeywords where t.contains(k) && t.count < 40 {
            t = t.replacingOccurrences(of: k, with: "")
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func load() async {
        guard state != .loading, !Task.isCancelled else { return }
        state = .loading
        do {
            let html = try await session.fetchHTML("forum.php?mod=viewthread&tid=\(tid)&mobile=2")
            try Task.checkCancellation()
            if DiscuzParser.looksLikeChallenge(html) {
                state = .failed("需要过验证，到「我的」里打开网页")
                return
            }
            detail = DiscuzParser.parseThreadDetail(html, tid: tid, base: session.baseURL)
            library.record(readingItem)
            state = .idle
        } catch {
            state = error is CancellationError ? .idle : .failed(error.localizedDescription)
        }
    }
}

private struct ImagePage: View {
    let url: URL
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            SiteImage(url: url, contentMode: .fit) {
                ProgressView()
            }
            .frame(maxWidth: .infinity)
        }
        .background(Color.black)
        .navigationTitle("图片")
        .navigationBarTitleDisplayMode(.inline)
    }
}
