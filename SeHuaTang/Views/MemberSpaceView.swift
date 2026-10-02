import SwiftUI

struct MemberSpaceView: View {
    let uid: Int
    var name: String
    @EnvironmentObject private var session: WebSession
    @State private var space: MemberSpace?
    @State private var state: LoadState = .idle

    var body: some View {
        VStack(spacing: 0) {
            ForumTopBar(title: displayName)
            Group {
                if state == .loading && space == nil {
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
                                .background(ForumChrome.card)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
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
        .toolbar(.hidden, for: .navigationBar)
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
        .background(ForumChrome.card)
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
        let path = "home.php?mod=space&uid=\(uid)&do=thread&view=me&from=space&mobile=2"
        do {
            let html = try await session.fetchHTML(path)
            var parsed = DiscuzParser.parseMemberSpace(html, uid: uid, base: session.baseURL)
            if parsed.name.isEmpty { parsed.name = name }
            space = parsed
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
