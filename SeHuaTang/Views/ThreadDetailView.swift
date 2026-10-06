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
    @State private var requestGate = ThreadRequestGate()
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
    @State private var showNativeReply = false
    @State private var replyDraft = ""
    @State private var publishedReply: NativeReplyProtocol.Success?
    @State private var showFavoriteConfirm = false
    @State private var favoriting = false
    @State private var favoriteMessage: String?
    @ObservedObject private var favoriteService = NativeFavoriteService.shared
    @State private var purchasing = false
    @State private var purchaseMessage: String?
    @ObservedObject private var purchaseService = NativePurchaseService.shared

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
        .confirmationDialog("收藏当前主题", isPresented: $showFavoriteConfirm, titleVisibility: .visible) {
            Button(favoriting ? "收藏中" : "确认收藏") { Task { await favorite() } }
                .disabled(favoriting || favoriteService.locked(host: session.host, tid: tid))
            Button("取消", role: .cancel) {}
        } message: {
            Text("将读取当前主题的收藏确认表单并原生提交一次。已收藏或结果未知不会自动重发。")
        }
        .alert("收藏结果", isPresented: Binding(get: { favoriteMessage != nil }, set: { if !$0 { favoriteMessage = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: { Text(favoriteMessage ?? "") }
        .confirmationDialog(purchaseTitle, isPresented: $showPurchaseConfirm, titleVisibility: .visible) {
            Button(purchasing ? "购买中" : "确认购买", role: .destructive) { Task { await purchase() } }
                .disabled(purchasing || purchaseService.locked(host: session.host, tid: tid))
            Button("取消", role: .cancel) {}
        } message: {
            Text("将使用当前登录会话提交一次原生购买。已购买不会重复付款；超时或结果未知不会自动重发。")
        }
        .alert("购买结果", isPresented: Binding(get: { purchaseMessage != nil }, set: { if !$0 { purchaseMessage = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: { Text(purchaseMessage ?? "") }
        .sheet(isPresented: $showNativeReply) {
            NativeReplySheet(tid: tid, fid: detail?.fid ?? sourceFID, title: detail?.title ?? title,
                             fallbackURL: postURL, draft: $replyDraft) { result in
                publishedReply = result
                Task { await load() }
            }
        }
        .task(id: postURL) {
            library.record(readingItem)
            if detail == nil || requestGate.source != postURL || requestGate.tid != tid { await load() }
        }
        .onDisappear {
            requestGate.invalidate()
            loadingReplies = false
            if state == .loading { state = .idle }
        }
    }

    // A compact local-reading action strip sits below the system navigation bar.
    private var detailToolbar: some View {
        HStack {
            Text("主题正文")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ForumChrome.secondary)
            Spacer()
            Button { Task { await load() } } label: {
                if state == .loading {
                    ProgressView().frame(width: 44, height: 44)
                } else {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium)).frame(minHeight: 44)
                }
            }
            .disabled(state == .loading || loadingReplies)
            .accessibilityHint("重新读取当前来源页；回复完成后可刷新隐藏资源。已追加回复将重置，不会自动回复或提交115")
            Button { showFavoriteConfirm = true } label: {
                Label("站点收藏", systemImage: "star")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ForumChrome.blue)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .disabled(favoriting || favoriteService.locked(host: session.host, tid: tid))
            .accessibilityHint("读取当前主题收藏表单后原生提交一次；已收藏或结果未知不会重发")
            if state != .loading, case .required(let price, _) = detail?.purchaseState {
                Button { showPurchaseConfirm = true } label: {
                    Label(price.map { "购买 · \($0)" } ?? "购买", systemImage: "cart")
                        .font(.system(size: 13, weight: .medium)).frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(purchasing || purchaseService.locked(host: session.host, tid: tid))
                .accessibilityHint("使用当前登录会话的原生购买接口。确认后只提交一次，结果未知不会自动重发")
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
                if d.purchaseState == .unknown {
                    Text("购买状态未确认：可能需要登录、验证或回复/阅读权限。请在原帖确认；不代表免费，不会自动付款。")
                        .font(.footnote).foregroundStyle(ForumChrome.secondary).padding(12)
                } else if d.purchaseState == .purchased {
                    Text("站点已确认当前账号购买；解锁内容按本次响应展示。")
                        .font(.footnote).foregroundStyle(ForumChrome.secondary).padding(12)
                }
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
                SelectableDetailText(text: NSAttributedString(string: d.title.isEmpty ? title : d.title, attributes: [.font: UIFont.preferredFont(forTextStyle: .headline)]), onLink: openBodyLink)
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

                if !d.magnets.isEmpty || !remainingAttachments(d).isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("下载附件").font(.caption.weight(.medium)).foregroundStyle(ForumChrome.secondary)
                        ForEach(d.magnets + remainingAttachments(d)) { m in
                            attachmentRow(m)
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
                                SelectableDetailText(text: attributedBody(runs), alignment: runs.first?.alignment == "center" ? .center : runs.first?.alignment == "right" ? .right : .left, onLink: openBodyLink)
                                    .multilineTextAlignment(runs.first?.alignment == "center" ? .center : runs.first?.alignment == "right" ? .trailing : .leading)
                                    .frame(maxWidth: .infinity, alignment: runs.first?.alignment == "center" ? .center : runs.first?.alignment == "right" ? .trailing : .leading)
                                    .font(.body)
                                    .foregroundStyle(ForumChrome.text)
                                    .lineSpacing(6)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            case .text(let text):
                                SelectableDetailText(text: NSAttributedString(string: text), onLink: openBodyLink)
                                    .font(.body)
                                    .foregroundStyle(ForumChrome.text)
                                    .lineSpacing(6)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            case .attachment(let item):
                                attachmentRow(ThreadAttachment(id: item.url.absoluteString, name: item.name, url: item.url, size: item.size, downloads: item.downloads))
                            case .attachmentIcon(let url):
                                SiteImage(url: url, contentMode: .fit) { Image(systemName: "doc") }
                                    .frame(width: 28, height: 28)
                                    .accessibilityLabel("附件图标（无可识别下载链接）")
                            case .emoticon(let smiley):
                                SiteImage(url: smiley.url, contentMode: .fit, preservesIntrinsicAspectRatio: false) {
                                    Color.clear
                                }
                                .frame(width: smiley.width, height: smiley.height)
                                .accessibilityLabel(smiley.alt)
                            case .images(let urls):
                                imageStrip(urls)
                            }
                        }
                        if let ratings = post.ratings { ratingsCard(ratings) }
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
            VStack(spacing: 6) {
                if let result = publishedReply {
                    NavigationLink {
                        ThreadDetailView(tid: tid, title: title, sourceFID: d.fid, sourceURL: result.url)
                    } label: {
                        Label("回复已发布 · 第\(result.page)页 · 查看新回复", systemImage: "checkmark.circle")
                            .font(.footnote)
                    }
                }
                actionBar(d)
            }
        }
    }

    private func actionBar(_ d: ThreadDetail) -> some View {
        HStack(spacing: 8) {
            Button {
                showNativeReply = true
            } label: {
                Label("回复", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .disabled(state == .loading || loadingReplies)
            Button { showFavoriteConfirm = true } label: {
                Label("站点收藏", systemImage: "star")
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .disabled(favoriting || favoriteService.locked(host: session.host, tid: tid))
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
        case emoticon(HTML.Emoticon)
        case attachment(HTML.Attachment)
        case attachmentIcon(URL)
    }

    private func bodyBlocks(_ html: String) -> [BodyBlock] {
        var result: [BodyBlock] = []
        for fragment in HTML.orderedContent(in: html, base: postURL) {
            switch fragment {
            case .richText(let runs): result.append(.richText(runs))
            case .text(let text): result.append(.text(text))
            case .attachment(let item): result.append(.attachment(item))
            case .attachmentIcon(let url): result.append(.attachmentIcon(url))
            case .emoticon(let smiley): result.append(.emoticon(smiley))
            case .image(let url):
                result.append(.images([url]))
            }
        }
        return result
    }

    private func remainingAttachments(_ detail: ThreadDetail) -> [ThreadAttachment] {
        let inlineIDs = Set(detail.posts.flatMap { HTML.attachmentMarkup(in: $0.htmlBody, base: postURL).files.map { $0.url.absoluteString } })
        return detail.attachments.filter { !inlineIDs.contains($0.id) }
    }

    private func attachmentRow(_ item: ThreadAttachment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.isMagnet || item.isED2K ? "link" : "doc.text")
                .font(.system(size: 24)).foregroundStyle(ForumChrome.blue)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                if item.size != nil || item.downloads != nil {
                    Text([item.size, item.downloads.map { "下载 \($0)" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(ForumChrome.secondary)
                }
                HStack(spacing: 12) {
                    Button(copiedAttachmentID == item.id ? "已复制" : "复制") {
                        UIPasteboard.general.string = item.url.absoluteString
                        copiedAttachmentID = item.id
                    }
                    if item.name.lowercased().hasSuffix(".txt") || item.url.pathExtension.lowercased() == "txt" {
                        NavigationLink("阅读") { TextAttachmentView(attachment: item) }
                    }
                    Button("打开") { openBodyLink(item.url) }
                }.font(.system(size: 13, weight: .semibold)).buttonStyle(.bordered)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
    }

    private func openBodyLink(_ url: URL) {
        guard let route = SiteRoute.resolve(url) else { return }
        if case .resource = route { SiteLinks.open(url) } else if linkRoute == nil { tappedLinkURL = url; linkRoute = route }
    }

    private func attributedBody(_ runs: [HTML.Inline]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in runs {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: run.bold ? UIFont(descriptor: UIFont.preferredFont(forTextStyle: .body).fontDescriptor.withSymbolicTraits(.traitBold) ?? UIFont.preferredFont(forTextStyle: .body).fontDescriptor, size: 0) : UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: run.color.map { UIColor(bodyColor($0)) } ?? UIColor.label
            ]
            if let url = run.url, SiteRoute.resolve(url) != nil { attributes[.link] = url }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
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

    private func ratingsCard(_ ratings: PostRatings) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("评分").font(.subheadline.bold())
            // Wrap on small screens / large accessibility text sizes rather than clip.
            Text(([ratings.participants.map { "参与人数 " + $0 }].compactMap { $0 } + ratings.totals).joined(separator: " · "))
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            if !ratings.entries.isEmpty {
                DisclosureGroup("评分明细（已加载 \(ratings.entries.count) 条）") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(ratings.entries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Button {
                                        if let uid = entry.uid { profile = MemberRoute(uid: uid, name: entry.name) }
                                    } label: {
                                        HStack(spacing: 6) {
                                            SiteImage(url: entry.avatarURL, preservesIntrinsicAspectRatio: false) {
                                                Image(systemName: "person.crop.square").resizable().scaledToFit()
                                            }
                                            .frame(width: 28, height: 28).clipped()
                                            Text(entry.name.isEmpty ? "用户" : entry.name).font(.caption)
                                                .lineLimit(2)
                                        }
                                    }
                                    .buttonStyle(.plain).disabled(entry.uid == nil)
                                    Spacer(minLength: 4)
                                    Text(entry.values.joined(separator: " · ")).font(.caption)
                                }
                                if !entry.reason.isEmpty {
                                    Text(entry.reason).font(.caption).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }.padding(.top, 6)
                }.font(.caption)
            } else {
                Text("评分明细未能安全解析，请查看原帖评分。")
                    .font(.caption).foregroundStyle(ForumChrome.secondary)
            }
            NavigationLink {
                LoginWebView(url: postURL, title: "原帖评分")
            } label: {
                Label("查看原帖评分 / 完整记录", systemImage: "globe").font(.caption)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(ForumChrome.side)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func cleaned(_ s: String) -> String {
        var t = s
        for k in SiteConfig.adKeywords where t.contains(k) && t.count < 40 {
            t = t.replacingOccurrences(of: k, with: "")
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var postURL: URL { sourceURL ?? session.url("forum.php?mod=viewthread&tid=\(tid)&mobile=2") }

    @MainActor private func loadMoreReplies() async {
        let origin = postURL
        let requestedTID = tid
        guard !loadingReplies, state != .loading, let url = nextPageURL,
              let token = requestGate.begin(tid: requestedTID, source: origin) else { return }
        loadingReplies = true
        replyLoadError = nil
        defer {
            if requestGate.generation == token { loadingReplies = false }
            requestGate.finish(token)
        }
        do {
            let html = try await session.fetchHTML(url.absoluteString, interactive: true)
            try Task.checkCancellation()
            guard requestGate.accepts(token, tid: tid, source: postURL) else { return }
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
            guard requestGate.accepts(token, tid: tid, source: postURL) else { return }
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
                panStatus = "提取中"
                let result = try await ResourceLinkExtractor.extractResult(detail: d, base: postURL)
                panStatus = "115目录阶段"
                let created = try await service.createOrReuseResource(tid: String(d.tid), title: d.title.isEmpty ? title : d.title, settings: settings)
                panStatus = "115提交阶段"
                resource = try await service.submit(urls: result.links, resourceID: created.id, settings: settings)
            }
            guard let resource else { throw SHT115Error.invalidInput }
            // Submission acceptance is distinct from video readiness. Unknown or
            // rejected results must not be presented as a completed submission.
            guard resource.tasks.contains(where: { $0.state == .accepted }) else {
                panStatus = resource.tasks.contains(where: { $0.state == .unknown || $0.state == .submitting })
                    ? "提交结果未知，请到115核对；不自动重发"
                    : "未有已接受任务，请检查提交结果"
                return
            }
            panStatus = "已接受，等待文件"
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
            panStatus = error is ResourceLinkExtractor.ExtractionError ? ResourceLinkExtractor.safeMessage(error) : (error is URLError ? "\(panStatus ?? "115读取阶段")：URLError \((error as! URLError).code.rawValue)；请核对任务，不自动重发。" : SHT115Settings.safeMessage(error))
        }
    }

    private var purchaseTitle: String {
        if case .required(let price, _) = detail?.purchaseState { return price.map { "购买主题 · \($0)" } ?? "购买主题" }
        return "购买主题"
    }

    @MainActor private func favorite() async {
        guard !favoriting, !favoriteService.locked(host: session.host, tid: tid) else { return }
        favoriting = true
        defer { favoriting = false }
        do {
            try await favoriteService.favorite(session: session, tid: tid)
            favoriteMessage = "收藏请求已确认。"
        } catch {
            favoriteMessage = (error as? LocalizedError)?.errorDescription ?? NativeFavoriteError.unknown.errorDescription
        }
    }

    @MainActor private func purchase() async {
        guard !purchasing, !purchaseService.locked(host: session.host, tid: tid) else { return }
        purchasing = true
        defer { purchasing = false }
        do {
            try await purchaseService.purchase(session: session, tid: tid, source: postURL)
            purchaseMessage = "购买请求已确认。正在刷新当前主题。"
            await load()
        } catch {
            purchaseMessage = (error as? LocalizedError)?.errorDescription ?? NativePurchaseError.unknown.errorDescription
        }
    }

    @MainActor private func load() async {
        let requestedURL = postURL
        let requestedTID = tid
        guard !loadingReplies, state != .loading, !Task.isCancelled,
              let token = requestGate.begin(tid: requestedTID, source: requestedURL) else { return }
        state = .loading
        detail?.purchaseState = .unknown // stale receipt/price must not survive a failed refresh
        defer { requestGate.finish(token) }
        do {
            let html = try await session.fetchHTML(requestedURL.absoluteString, interactive: true)
            try Task.checkCancellation()
            guard requestGate.accepts(token, tid: tid, source: postURL) else { return }
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
            guard requestGate.accepts(token, tid: tid, source: postURL) else { return }
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

/// Native selection handles, non-editable and non-scrolling: the parent owns scrolling.
private struct SelectableDetailText: UIViewRepresentable {
    let text: NSAttributedString
    var alignment: NSTextAlignment = .left
    var onLink: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onLink: onLink) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator
        view.adjustsFontForContentSizeCategory = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.onLink = onLink
        let styled = NSMutableAttributedString(attributedString: text)
        let range = NSRange(location: 0, length: styled.length)
        styled.enumerateAttributes(in: range) { attributes, part, _ in
            if attributes[.font] == nil { styled.addAttribute(.font, value: UIFont.preferredFont(forTextStyle: .body), range: part) }
            if attributes[.foregroundColor] == nil { styled.addAttribute(.foregroundColor, value: UIColor.label, range: part) }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineSpacing = 6
        styled.addAttribute(.paragraphStyle, value: paragraph, range: range)
        if view.attributedText != styled { view.attributedText = styled }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var onLink: (URL) -> Void
        init(onLink: @escaping (URL) -> Void) { self.onLink = onLink }
        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
            if interaction == .invokeDefaultAction { onLink(URL) }
            return false
        }
    }
}
