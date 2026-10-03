import SwiftUI

struct MemberSpaceView: View {
    let uid: Int
    var name: String
    @EnvironmentObject private var session: WebSession
    @State private var space: MemberSpace?
    @State private var state: LoadState = .idle
    @State private var loadingMore = false
    @State private var status = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if (state == .loading || state == .idle) && space == nil {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = state.errorMessage, space == nil {
                    ContentUnavailableView {
                        Label("主页加载失败", systemImage: "person.crop.circle.badge.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("重试") { Task { await load() } }
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            header
                            if !status.isEmpty {
                                Text(status).font(.footnote).foregroundStyle(.secondary)
                                Button("重试加载主题") { Task { await loadMore() } }
                            }
                            if let space, !space.threads.isEmpty {
                                LazyVStack(spacing: 0) {
                                    ForEach(space.threads) { item in
                                        NavigationLink {
                                            ThreadDetailView(tid: item.id, title: item.title)
                                        } label: {
                                            ThreadCard(item: item)
                                        }
                                        .buttonStyle(.plain)
                                        Divider().padding(.leading, 76)
                                    }
                                }
                                .background(ForumChrome.bar)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                if space.hasNext {
                                    Button(loadingMore ? "正在加载下一页" : "加载更多主题") { Task { await loadMore() } }
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                        .disabled(loadingMore)
                                } else {
                                    Text("已显示全部 \(space.threads.count) 个主题")
                                        .font(.caption).foregroundStyle(ForumChrome.secondary)
                                        .frame(maxWidth: .infinity)
                                }
                            } else if state != .loading {
                                ContentUnavailableView("没有可显示的主题", systemImage: "text.bubble", description: Text("已打开该用户主页。主题可能需要登录，或页面结构未能识别。"))
                            }
                        }
                        .padding(12)
                    }
                }
            }
        }
        .background(ForumChrome.page)
        .forumNavigation(title: displayName)
        .task { await load() }
    }

    private var displayName: String {
        let value = space?.name.isEmpty == false ? (space?.name ?? name) : name
        return value.isEmpty ? "用户 \(uid)" : value
    }

    private var header: some View {
        HStack(spacing: 12) {
            avatar(space?.avatarURL)
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName).font(.system(size: 18, weight: .semibold))
                Text("UID \(uid)").font(.caption).foregroundStyle(ForumChrome.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(ForumChrome.bar)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func avatar(_ url: URL?) -> some View {
        Group {
            if let url {
                SiteImage(url: url) { ForumChrome.page }
            } else {
                Image(systemName: "person.fill")
                    .foregroundStyle(ForumChrome.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ForumChrome.page)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(Circle())
    }

    @MainActor private func load() async {
        guard state != .loading else { return }
        state = .loading
        let paths = [
            "home.php?mod=space&uid=\(uid)&do=thread&view=me&from=space&mobile=2",
            "home.php?mod=space&uid=\(uid)&mobile=2"
        ]
        do {
            var html = ""
            var lastError: Error = URLError(.timedOut)
            for path in paths {
                do {
                    html = try await withTimeout(12) { try await session.fetchHTML(path, timeout: 10) }
                    lastError = URLError(.timedOut)
                    break
                } catch {
                    lastError = error
                }
            }
            if html.isEmpty { throw lastError }
            var parsed = DiscuzParser.parseMemberSpace(html, uid: uid, base: session.url(paths[0]))
            if parsed.name.isEmpty { parsed.name = name }
            space = parsed
            state = .idle
            if parsed.hasNext { await loadMore(auto: true) }
        } catch {
            state = .failed("个人主页加载超时，请重试")
        }
    }

    @MainActor private func loadMore(auto: Bool = false) async {
        guard let current = space, current.hasNext, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        let next = current.page + 1
        let limit = min(current.totalPages ?? (next + 4), next + 9)
        var merged = current
        while merged.hasNext, merged.page < limit {
            let path = "home.php?mod=space&uid=\(uid)&do=thread&view=me&from=space&mobile=2&page=\(merged.page + 1)"
            do {
                let html = try await withTimeout(12) { try await session.fetchHTML(path, timeout: 10) }
                let parsed = DiscuzParser.parseMemberSpace(html, uid: uid, base: session.url(path))
                let existing = Set(merged.threads.map(\.id))
                merged.threads.append(contentsOf: parsed.threads.filter { !existing.contains($0.id) })
                merged.page = max(parsed.page, merged.page + 1)
                merged.totalPages = parsed.totalPages ?? merged.totalPages
                merged.hasNext = parsed.hasNext && (merged.totalPages.map { merged.page < $0 } ?? parsed.hasNext)
                if parsed.threads.isEmpty { merged.hasNext = false }
                space = merged
            } catch {
                if !auto { status = "后续主题加载失败，可再试" }
                return
            }
        }
    }

    private func withTimeout<T>(_ seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw URLError(.timedOut)
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }
}
