import SwiftUI

struct ThreadListView: View {
    let board: ForumBoard
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var session: WebSession
    @State private var typeID = 0
    @State private var order = "dateline"
    @State private var visibleThreadID: Int?

    private let orders: [(String, String)] = [
        ("dateline", "最新"),
        ("heats", "热门"),
        ("replies", "回复"),
        ("views", "查看")
    ]

    var body: some View {
        VStack(spacing: 0) {
            ForumTopBar(title: board.name) {
                Task { await reload() }
            }
            boardHeader
            if store.threadTypes.count > 1 {
                typeBar
            }
            orderBar
            ChallengeBanner()
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let error = store.threadState.errorMessage, store.threads.isEmpty {
                        ContentUnavailableView {
                            Label("加载失败", systemImage: "wifi.exclamationmark")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("重试") { Task { await reload() } }
                        }
                        .padding(.vertical, 32)
                    } else if store.threads.isEmpty && store.threadState == .idle {
                        ContentUnavailableView("暂无帖子", systemImage: "text.bubble", description: Text("试试其他分类或下拉刷新"))
                            .padding(.vertical, 32)
                    }
                    ForEach(store.threads) { item in
                        NavigationLink {
                            ThreadDetailView(tid: item.id, title: item.title)
                        } label: {
                            ThreadCard(item: item)
                        }
                        .id(item.id)
                        .buttonStyle(.plain)
                        .onAppear {
                            if item.id == store.threads.last?.id {
                                Task { await store.loadMore() }
                            }
                        }
                    }
                    if store.threadState == .loading {
                        ProgressView().padding()
                    } else if let error = store.threadState.errorMessage, !store.threads.isEmpty {
                        VStack(spacing: 8) {
                            Text(error).font(.footnote).foregroundStyle(ForumChrome.secondary)
                            Button("重试加载下一页") { Task { await store.loadMore() } }
                        }
                        .padding(16)
                    } else if !store.threads.isEmpty {
                        Text(store.threadHasNext ? "上滑加载更多" : "已显示全部帖子")
                            .font(.caption)
                            .foregroundStyle(ForumChrome.secondary)
                            .padding(16)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $visibleThreadID, anchor: .top)
            .background(ForumChrome.page)
            .refreshable { await reload() }
        }
        .background(ForumChrome.page)
        .tint(ForumChrome.blue)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            // A popped detail must not clear the list or fetch page one again.
            if store.currentFID == board.id,
               store.currentTypeID == typeID, store.currentOrder == order,
               !store.threads.isEmpty { return }
            await reload()
        }
    }

    private var boardHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(board.name)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(ForumChrome.text)
                Text(board.meta.isEmpty ? "版块主题 · 浏览与交流" : board.meta)
                    .font(.caption)
                    .foregroundStyle(ForumChrome.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            NavigationLink {
                LoginWebView(url: session.url("forum.php?mod=post&action=newthread&fid=\(board.id)&mobile=2"), title: "发帖 · 网页表单")
            } label: {
                Label("发帖", systemImage: "square.and.pencil")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 36)
                    .foregroundStyle(ForumChrome.blue)
                    .background(ForumChrome.blue.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("发帖，打开网页表单")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(ForumChrome.bar)
        .overlay(alignment: .bottom) { ForumChrome.line.frame(height: 0.5) }
    }

    private var typeBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(store.threadTypes) { t in
                    Button {
                        typeID = t.id
                        Task { await reload() }
                    } label: {
                        Text(t.name)
                            .font(.system(size: 15, weight: typeID == t.id ? .semibold : .regular))
                            .foregroundStyle(typeID == t.id ? ForumChrome.blue : ForumChrome.text)
                            .padding(.horizontal, 14)
                            .frame(height: 42)
                            .overlay(alignment: .bottom) {
                                if typeID == t.id {
                                    Capsule().fill(ForumChrome.blue).frame(width: 22, height: 3)
                                        .padding(.bottom, 4)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
        }
        .background(ForumChrome.bar)
    }

    private var orderBar: some View {
        HStack(spacing: 16) {
            ForEach(orders, id: \.0) { item in
                Button {
                    order = item.0
                    Task { await reload() }
                } label: {
                    Text(item.1)
                        .font(.system(size: 13, weight: order == item.0 ? .semibold : .regular))
                        .foregroundStyle(order == item.0 ? ForumChrome.blue : ForumChrome.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(ForumChrome.bar)
        .overlay(alignment: .bottom) { ForumChrome.line.frame(height: 0.5) }
    }

    private func reload() async {
        await store.loadThreads(fid: board.id, typeid: typeID, order: order)
    }
}

struct ThreadCard: View {
    let item: ThreadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(item.author.isEmpty ? "匿名" : item.author)
                if !item.dateText.isEmpty { Text("·"); Text(item.dateText) }
                Spacer(minLength: 0)
                if item.isSticky {
                    Text("置顶").foregroundStyle(ForumChrome.blue)
                }
            }
            .font(.caption)
            .foregroundStyle(ForumChrome.secondary)
            Text(item.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ForumChrome.text)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if !item.excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(item.excerpt)
                    .font(.system(size: 14))
                    .foregroundStyle(ForumChrome.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            if !item.previewURLs.isEmpty {
                GeometryReader { geometry in
                    let previews = Array(item.previewURLs.prefix(3))
                    let width = max(0, (geometry.size.width - CGFloat(previews.count - 1) * 8) / CGFloat(previews.count))
                    HStack(spacing: 8) {
                        ForEach(previews, id: \.self) { url in
                            SiteImage(url: url, contentMode: .fit) { ForumChrome.page }
                                .frame(width: width, height: 132)
                                .background(ForumChrome.page)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .accessibilityLabel("帖子图片预览")
                        }
                    }
                }
                .frame(height: 132)
            }
            HStack(spacing: 16) {
                Label(item.replies.isEmpty ? "0" : item.replies, systemImage: "bubble")
                if !item.likes.isEmpty { Label(item.likes, systemImage: "hand.thumbsup") }
                if !item.views.isEmpty { Label(item.views, systemImage: "eye") }
            }
            .font(.caption)
            .foregroundStyle(ForumChrome.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ForumChrome.bar)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            ForumChrome.line.frame(height: 0.5).padding(.horizontal, 16)
        }
    }
}
