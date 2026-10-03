import SwiftUI
import UIKit

struct ThreadDetailView: View {
    let tid: Int
    let title: String
    var sourceFID: Int? = nil
    var sourceURL: URL? = nil
    @EnvironmentObject var session: WebSession
    @EnvironmentObject var store: AppStore
    @ObservedObject private var library = ReadingLibrary.shared
    @State private var detail: ThreadDetail?
    @State private var state: LoadState = .idle
    @State private var copied = false
    @State private var playVideos: [SHT115Video] = []
    @State private var showPlayer = false
    @State private var panStatus: String?
    @State private var copiedAttachmentID: String?
    @State private var nextPageURL: URL?
    @State private var loadedPage = 1
    @State private var loadingReplies = false
    @State private var replyLoadError: String?
    @State private var profile: MemberRoute?
    @State private var linkRoute: SiteRoute?
    @State private var tappedLinkURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            detailToolbar
            Group {
                if (state == .loading || state == .idle) && detail == nil {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = state.errorMessage, detail == nil {
                    ContentUnavailableView {
                        Label("加载失败", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("重试") { Task { await load() } }
                        NavigationLink("登录 / 完成验证") {
                            LoginWebView(url: session.url("forum.php?forumlist=1&mobile=2"), title: "登录 / 完成验证")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let detail {
                    content(detail)
                }
            }
            .background(ForumChrome.page)
        }
        .background(ForumChrome.page)
        .tint(ForumChrome.blue)
        .forumNavigation(title: detail?.boardName.isEmpty == false ? (detail?.boardName ?? "帖子") : "帖子")
        .fullScreenCover(isPresented: $showPlayer) {
            Pan115InlinePlayer(title: detail?.title.isEmpty == false ? (detail?.title ?? title) : title, videos: playVideos)
        }
        .navigationDestination(item: $profile) { route in
            MemberSpaceView(uid: route.uid, name: route.name)
        }
        .navigationDestination(item: $linkRoute) { route in
            switch route {
            case .thread(let id): ThreadDetailView(tid: id, title: "帖子", sourceURL: tappedLinkURL)
            case .forum(let id): ThreadListView(board: ForumBoard(id: id, name: "版块", today: 0, meta: ""))
            case .member(let id): MemberSpaceView(uid: id, name: "用户")
            case .web(let url): LoginWebView(url: url, title: "网页")
            case .resource: EmptyView()
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            openBodyLink(url)
            return .handled
        })
        .task {
            library.record(readingItem)
            if detail == nil { await load() }
        }
    }

    // A compact local-reading action strip sits below the system navigation bar.
    private var detailToolbar: some View {
        HStack {
            Text("主题正文")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ForumChrome.secondary)
            Spacer()
            NavigationLink {
                LoginWebView(url: session.url("home.php?mod=spacecp&ac=favorite&type=thread&id=\(tid)&mobile=2"), title: "站点收藏 · 确认表单")
            } label: {
                Label("站点收藏", systemImage: "star")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ForumChrome.blue)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            if SiteConfig.allowsPurchase(fid: detail?.fid ?? sourceFID) {
                NavigationLink {
                    LoginWebView(url: postURL, title: "资源出售 · 手动确认购买")
                } label: {
                    Label("购买", systemImage: "cart")
                        .font(.system(size: 13, weight: .medium))
                        .frame(minHeight: 44)
                }
                .accessibilityHint("打开站点表单；请核对价格并手动确认，不会自动扣积分")
            }
            NavigationLink {
                LoginWebView(url: postURL, title: "查看原帖")
            } label: {
                Label("原帖", systemImage: "globe")
                    .font(.system(size: 13, weight: .medium))
                    .frame(minHeight: 44)
            }
        }
        .padding(.horizontal, 16)
        .background(ForumChrome.bar)
        .overlay(alignment: .bottom) { ForumChrome.line.frame(height: 0.5) }
    }

    private var readingItem: ThreadItem {
        var item = store.threads.first(where: { $0.id == tid }) ?? ThreadItem(
            id: tid, title: title, excerpt: "", author: "", authorID: nil,
            avatarURL: nil, coverURL: nil, dateText: "", replies: "",
            likes: "", views: "", isSticky: false, fid: sourceFID
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
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .foregroundStyle(ForumChrome.text)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                VStack(alignment: .leading, spacing: 8) {
                    Button { if panStatus == nil { Task { await play115(d) } } else { panStatus = nil } } label: {
                        HStack {
                            Label("115 归档 / 播放", systemImage: "play.rectangle.fill")
                            Spacer()
                            Image(systemName: panStatus == nil ? "chevron.right" : "xmark.circle")
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel(panStatus == nil ? "提交115并直接播放" : "清除115操作状态")
                    if let panStatus {
                        Text(panStatus)
                            .font(.footnote)
                            .foregroundStyle(ForumChrome.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("115状态：\(panStatus)")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(ForumChrome.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(ForumChrome.side, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

                if let post = d.posts.first {
                    authorBar(post)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }

                if !d.magnets.isEmpty || !d.attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("下载附件").font(.caption.weight(.medium)).foregroundStyle(ForumChrome.secondary)
                        ForEach(d.magnets + d.attachments) { m in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: m.isMagnet ? "link" : "arrow.down.doc")
                                        .foregroundStyle(ForumChrome.blue)
                                    Text(m.isMagnet ? "磁力链接" : (m.isED2K ? "eD2k" : m.name))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                HStack(spacing: 12) {
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
                                        Button("打开") { openBodyLink(m.url) }
                                            .font(.system(size: 13, weight: .semibold))
                                }
                                }
                                }
                            .font(.subheadline)
                            .buttonStyle(.bordered)
                            .frame(minHeight: 44)
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
                        ForEach(Array(bodyBlocks(post.htmlBody).enumerated()), id: \.offset) { _, fragment in
                            switch fragment {
                            case .richText(let runs):
                                Text(attributedBody(runs))
                                    .multilineTextAlignment(runs.first?.alignment == "center" ? .center : runs.first?.alignment == "right" ? .trailing : .leading)
                                    .frame(maxWidth: .infinity, alignment: runs.first?.alignment == "center" ? .center : runs.first?.alignment == "right" ? .trailing : .leading)
                                    .font(.body)
                                    .foregroundStyle(ForumChrome.text)
                                    .lineSpacing(6)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            case .text(let text):
                                Text(text)
                                    .font(.body)
                                    .foregroundStyle(ForumChrome.text)
                                    .lineSpacing(6)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            case .images(let urls):
                                imageStrip(urls)
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ForumChrome.page, in: RoundedRectangle(cornerRadius: 14))
                    .overlay { RoundedRectangle(cornerRadius: 14).stroke(ForumChrome.line, lineWidth: 0.5) }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                }

                if d.posts.allSatisfy(\.images.isEmpty), !d.images.isEmpty {
                    imageStrip(d.images)
                        .padding(16)
                }
                if let error = replyLoadError {
                    Text(error).font(.footnote).foregroundStyle(ForumChrome.secondary).padding(16)
                }
                if nextPageURL != nil {
                    Button { Task { await loadMoreReplies() } } label: {
                        HStack {
                            if loadingReplies { ProgressView() }
                            Text(loadingReplies ? "正在加载回复…" : "加载更多回复")
                        }.frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .disabled(loadingReplies || state == .loading)
                    .padding(16)
                }
                Text("主题正文与各楼层独立显示，已加载至第\(loadedPage)页。更多回复按网页分页加载；权限隐藏内容需在网页查看。")
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
        HStack(spacing: 8) {
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
        .font(.system(size: 12, weight: .medium))
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private func authorBar(_ post: ThreadPost, isOriginal: Bool = true) -> some View {
        Button {
            if let uid = post.authorID { profile = MemberRoute(uid: uid, name: post.author) }
        } label: {
            HStack(spacing: 10) {
                avatar(post.avatarURL)
                VStack(alignment: .leading, spacing: 3) {
                    Text(post.author.isEmpty ? (isOriginal ? "楼主" : "回复者") : post.author)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
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
        .buttonStyle(.plain)
        .disabled(post.authorID == nil)
        .accessibilityLabel("打开\(post.author.isEmpty ? "用户" : post.author)的主页")
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

    // Coalesce only adjacent image fragments; text always stays at its original position.
    private enum BodyBlock {
        case richText([HTML.Inline])
        case text(String)
        case images([URL])
    }

    private func bodyBlocks(_ html: String) -> [BodyBlock] {
        var result: [BodyBlock] = []
        for fragment in HTML.orderedContent(in: html, base: postURL) {
            switch fragment {
            case .richText(let runs): result.append(.richText(runs))
            case .text(let text): result.append(.text(text))
            case .image(let url):
                result.append(.images([url]))
            }
        }
        return result
    }

    private func openBodyLink(_ url: URL) {
        guard let route = SiteRoute.resolve(url) else { return }
        if case .resource = route { SiteLinks.open(url) } else if linkRoute == nil { tappedLinkURL = url; linkRoute = route }
    }

    private func attributedBody(_ runs: [HTML.Inline]) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            var text = AttributedString(run.text)
            if run.bold { text.font = .body.bold() }
            if let color = run.color { text.foregroundColor = bodyColor(color) }
            if let url = run.url, SiteRoute.resolve(url) != nil { text.link = url }
            result.append(text)
        }
        return result
    }

    private func bodyColor(_ value: String) -> Color {
        let named: [String: Color] = ["red": .red, "pink": .pink, "blue": .blue, "green": .green, "purple": .purple, "orange": .orange]
        if let color = named[value.lowercased()] { return color }
        let hex = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if hex.count == 6, let rgb = UInt32(hex, radix: 16) {
            // Semantic accent colors remain legible in both appearance modes.
            if rgb == 0 || rgb == 0xffffff { return ForumChrome.text }
            return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
        }
        return ForumChrome.text
    }

    @ViewBuilder
    private func imageStrip(_ urls: [URL]) -> some View {
        if urls.count == 1, let url = urls.first {
            NavigationLink {
                ImagePage(url: url)
            } label: {
                SiteImage(url: url, contentMode: .fit) {
                    ProgressView().frame(maxWidth: .infinity).frame(height: 120)
                }
                .frame(maxWidth: .infinity)
                .background(ForumChrome.page)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看原图")
        } else {
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(Array(urls.enumerated()), id: \.offset) { _, url in
                        NavigationLink {
                            ImagePage(url: url)
                        } label: {
                            SiteImage(url: url, contentMode: .fit) {
                                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            .frame(height: 180)
                            .frame(minWidth: 100, maxWidth: 280)
                            .background(ForumChrome.page)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("查看原图")
                    }
                }
                .padding(.bottom, 4)
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

    private var postURL: URL { sourceURL ?? session.url("forum.php?mod=viewthread&tid=\(tid)&mobile=2") }

    private func loadMoreReplies() async {
        guard !loadingReplies, state != .loading, let url = nextPageURL else { return }
        loadingReplies = true
        replyLoadError = nil
        defer { loadingReplies = false }
        do {
            let html = try await session.fetchHTML(url.absoluteString)
            try Task.checkCancellation()
            guard !DiscuzParser.looksLikeChallenge(html) else {
                replyLoadError = "需要网页验证；已加载正文仍保留，可完成验证后重试"
                return
            }
            let page = HTML.queryInt("page", in: url.absoluteString)
                ?? HTML.firstMatch(#"thread-\d+-(\d+)-\d+\.html"#, in: url.absoluteString).flatMap(Int.init)
                ?? (loadedPage + 1)
            let more = DiscuzParser.parseThreadDetail(html, tid: tid, base: url, fallbackTitle: title)
            guard !more.posts.isEmpty, var current = detail else {
                replyLoadError = "未取得下一页回复，请检查网页权限后重试"
                return
            }
            var ids = Set(current.posts.map(\.id))
            current.posts += more.posts.filter { ids.insert($0.id).inserted }
            // Preserve page-one download/115 inputs: later replies are not the OP.
            detail = current
            loadedPage = page
            nextPageURL = DiscuzParser.nextThreadPage(in: html, tid: tid, base: url, page: page)
        } catch {
            if !(error is CancellationError) { replyLoadError = error.localizedDescription }
        }
    }

    @MainActor private func play115(_ d: ThreadDetail) async {
        panStatus = "提取中"
        do {
            let settings = SHT115Settings.load()
            try settings.validate()
            let service = try Pan115UIService.get()
            let existing = await service.resources().first { $0.tid == String(d.tid) && $0.parentCID == settings.parentCID && $0.directoryCID != nil }
            var resource = existing
            if existing?.tasks.contains(where: { $0.state == .accepted }) != true {
                panStatus = "提交中"
                let result = try await ResourceLinkExtractor.extractResult(detail: d, base: postURL)
                let created = try await service.createOrReuseResource(tid: String(d.tid), title: d.title.isEmpty ? title : d.title, settings: settings)
                resource = try await service.submit(urls: result.links, resourceID: created.id, settings: settings)
            }
            guard let resource else { throw SHT115Error.invalidInput }
            panStatus = "等待文件"
            for _ in 0..<12 {
                guard panStatus != nil else { return }
                let listing = try await service.listVideos(resourceID: resource.id, settings: settings)
                if listing.videos.isEmpty {
                    for archive in listing.archives.prefix(2) {
                        _ = try? await service.requestExtraction(archive: archive, resourceID: resource.id, settings: settings, confirmed: true)
                    }
                }
                if !listing.videos.isEmpty {
                    playVideos = listing.videos
                    showPlayer = true
                    panStatus = nil
                    return
                }
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
            panStatus = "已提交，文件未就绪"
        } catch {
            panStatus = SHT115Settings.safeMessage(error)
        }
    }

    private func load() async {
        guard !loadingReplies, state != .loading, !Task.isCancelled else { return }
        state = .loading
        do {
            let html = try await session.fetchHTML(postURL.absoluteString)
            try Task.checkCancellation()
            if DiscuzParser.looksLikeChallenge(html) {
                state = .failed("需要过验证，到「我的」里打开网页")
                return
            }
            let parsed = DiscuzParser.parseThreadDetail(html, tid: tid, base: postURL, fallbackTitle: title)
            guard !parsed.posts.isEmpty else {
                state = .failed("未取得可读正文，可能需登录或网页权限；请到「我的」检查网页")
                return
            }
            detail = parsed
            loadedPage = HTML.queryInt("page", in: postURL.absoluteString) ?? Int(HTML.firstMatch(#"thread-\d+-(\d+)-"#, in: postURL.path) ?? "1") ?? 1
            nextPageURL = DiscuzParser.nextThreadPage(in: html, tid: tid, base: postURL, page: loadedPage)
            replyLoadError = nil
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
        ScrollView(.vertical) {
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
