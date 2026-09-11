import SwiftUI
import UIKit

struct ThreadDetailView: View {
    let tid: Int
    let title: String
    @EnvironmentObject var session: WebSession
    @State private var detail: ThreadDetail?
    @State private var state: LoadState = .idle
    @State private var showWeb = false

    var body: some View {
        Group {
            switch state {
            case .loading, .idle:
                if let detail {
                    content(detail)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .failed(let msg):
                ContentUnavailableView {
                    Label("加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(msg)
                } actions: {
                    Button("重试") { Task { await load() } }
                    Button("用网页打开") { showWeb = true }
                }
            }
        }
        .navigationTitle(detail?.title.isEmpty == false ? (detail?.title ?? title) : title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showWeb = true } label: { Image(systemName: "safari") }
            }
        }
        .sheet(isPresented: $showWeb) {
            NavigationStack {
                LoginWebView(url: session.url("forum.php?mod=viewthread&tid=\(tid)&mobile=2"), title: "原网页")
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private func content(_ d: ThreadDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !d.magnets.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("下载").font(.headline)
                        ForEach(d.magnets) { m in
                            HStack {
                                Image(systemName: m.isMagnet ? "link" : "arrow.down.doc")
                                Text(m.isMagnet ? "磁力链接" : m.name)
                                    .lineLimit(1)
                                Spacer()
                                Button("复制") {
                                    UIPasteboard.general.string = m.url.absoluteString
                                }
                                .buttonStyle(.bordered)
                                Button("打开") {
                                    UIApplication.shared.open(m.url)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .font(.subheadline)
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                if !d.attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("附件").font(.headline)
                        ForEach(d.attachments) { a in
                            Link(a.name, destination: a.url)
                                .font(.subheadline)
                        }
                    }
                }

                if !d.images.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(d.images, id: \.self) { url in
                                AsyncImage(url: url) { phase in
                                    switch phase {
                                    case .success(let img):
                                        img.resizable().scaledToFill()
                                    default:
                                        Color(.tertiarySystemFill)
                                    }
                                }
                                .frame(width: 160, height: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                }

                ForEach(d.posts) { post in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(post.author.isEmpty ? "楼主" : post.author)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(post.dateText).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(cleaned(post.plainText))
                            .font(.body)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 6)
                    Divider()
                }
            }
            .padding()
        }
    }

    private func cleaned(_ s: String) -> String {
        var t = s
        for k in SiteConfig.adKeywords {
            t = t.replacingOccurrences(of: k, with: "")
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func load() async {
        state = .loading
        do {
            let html = try await session.fetchHTML("forum.php?mod=viewthread&tid=\(tid)&mobile=2")
            if DiscuzParser.looksLikeChallenge(html) {
                state = .failed("需要过验证，点右上角用网页打开")
                return
            }
            detail = DiscuzParser.parseThreadDetail(html, tid: tid, base: session.baseURL)
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
