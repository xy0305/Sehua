import SwiftUI
import UIKit

struct ThreadDetailView: View {
    let tid: Int
    let title: String
    @EnvironmentObject var session: WebSession
    @State private var detail: ThreadDetail?
    @State private var state: LoadState = .idle
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            ForumTopBar(title: detail?.boardName.isEmpty == false ? (detail?.boardName ?? "帖子") : "帖子")
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
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
    }

    private func content(_ d: ThreadDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(d.title.isEmpty ? title : d.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color(white: 0.08))
                    .padding(.horizontal, 16)
                    .padding(.top, 14)

                if let post = d.posts.first {
                    authorBar(post)
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
                                Button(copied ? "已复制" : "复制") {
                                    UIPasteboard.general.string = m.url.absoluteString
                                    copied = true
                                }
                                .font(.system(size: 13, weight: .semibold))
                                Button("打开") { SiteLinks.open(m.url) }
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .font(.system(size: 14))
                        }
                    }
                    .padding(14)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 12)
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
                    .padding(14)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 12)
                }

                ForEach(d.posts) { post in
                    VStack(alignment: .leading, spacing: 10) {
                        if d.posts.first?.id != post.id {
                            HStack {
                                Text(post.author.isEmpty ? "回复" : post.author)
                                    .font(.system(size: 14, weight: .semibold))
                                Spacer()
                                Text(post.dateText)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color(white: 0.5))
                            }
                        }
                        Text(cleaned(post.plainText))
                            .font(.system(size: 16))
                            .foregroundStyle(Color(white: 0.12))
                            .lineSpacing(6)
                            .textSelection(.enabled)
                        if !post.images.isEmpty {
                            imageStrip(post.images)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 12)
                }

                if d.posts.allSatisfy(\.images.isEmpty), !d.images.isEmpty {
                    imageStrip(d.images)
                        .padding(.horizontal, 12)
                }
            }
            .padding(.bottom, 24)
        }
    }

    private func authorBar(_ post: ThreadPost) -> some View {
        HStack(spacing: 10) {
            avatar(post.avatarURL)
            VStack(alignment: .leading, spacing: 3) {
                Text(post.author.isEmpty ? "楼主" : post.author)
                    .font(.system(size: 15, weight: .semibold))
                if !post.dateText.isEmpty {
                    Text(post.dateText)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(white: 0.5))
                }
            }
            Spacer()
            Text("楼主")
                .font(.system(size: 12))
                .foregroundStyle(ForumChrome.blue)
        }
        .padding(.horizontal, 16)
    }

    private func avatar(_ url: URL?) -> some View {
        Group {
            if let url {
                SiteImage(url: url) {
                    Color(white: 0.92)
                }
            } else {
                Image(systemName: "person.fill")
                    .foregroundStyle(Color(white: 0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(white: 0.93))
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
    }

    private func imageStrip(_ urls: [URL]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(urls, id: \.self) { url in
                    SiteImage(url: url) {
                        Color(white: 0.94)
                    }
                    .frame(width: 160, height: 210)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
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
        state = .loading
        do {
            let html = try await session.fetchHTML("forum.php?mod=viewthread&tid=\(tid)&mobile=2")
            if DiscuzParser.looksLikeChallenge(html) {
                state = .failed("需要过验证，到「我的」里打开网页")
                return
            }
            detail = DiscuzParser.parseThreadDetail(html, tid: tid, base: session.baseURL)
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
