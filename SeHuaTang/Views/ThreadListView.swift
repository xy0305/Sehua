import SwiftUI

struct ThreadListView: View {
    let board: ForumBoard
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var session: WebSession
    @State private var typeID = 0
    @State private var order = "dateline"

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
            }
            .background(ForumChrome.page)
            .refreshable { await reload() }
        }
        .background(ForumChrome.page)
        .tint(ForumChrome.blue)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .task { await reload() }
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
        HStack(alignment: .center, spacing: 12) {
            if let url = item.coverURL {
                SiteImage(url: url) { ForumChrome.page }
                    .frame(width: 60, height: 60)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if item.isSticky {
                        Text("置顶")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(ForumChrome.blue)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(ForumChrome.blue.opacity(0.08))
                    }
                    Text(item.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(ForumChrome.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                HStack(spacing: 6) {
                    Text(item.author.isEmpty ? "匿名" : item.author)
                        .lineLimit(1)
                    if !item.dateText.isEmpty {
                        Text("·")
                        Text(item.dateText).lineLimit(1)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(ForumChrome.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 3) {
                Text(item.replies.isEmpty ? "0" : item.replies)
                    .font(.system(size: 14, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(ForumChrome.secondary)
                Text("回复")
                    .font(.system(size: 10))
                    .foregroundStyle(ForumChrome.secondary)
            }
            .frame(minWidth: 34)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .background(ForumChrome.bar)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            ForumChrome.line.frame(height: 0.5).padding(.leading, 16)
        }
    }
}
