import SwiftUI

struct ThreadListView: View {
    let board: ForumBoard
    @EnvironmentObject var store: AppStore
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
            if store.threadTypes.count > 1 {
                typeBar
            }
            orderBar
            ScrollView {
                LazyVStack(spacing: 10) {
                    if let error = store.threadState.errorMessage, store.threads.isEmpty {
                        ContentUnavailableView(error, systemImage: "wifi.exclamationmark")
                            .padding(.top, 40)
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
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(ForumChrome.page)
            .refreshable { await reload() }
        }
        .background(ForumChrome.page)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .task { await reload() }
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
                            .foregroundStyle(typeID == t.id ? ForumChrome.blue : Color(white: 0.28))
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
        .background(Color.white)
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
                        .foregroundStyle(order == item.0 ? ForumChrome.blue : Color(white: 0.45))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(Color.white)
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
            HStack(spacing: 8) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.author.isEmpty ? "匿名" : item.author)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color(white: 0.15))
                        if item.isSticky {
                            Text("置顶")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(ForumChrome.blue)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(ForumChrome.blue.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    if !item.dateText.isEmpty {
                        Text(item.dateText)
                            .font(.system(size: 11))
                            .foregroundStyle(Color(white: 0.55))
                    }
                }
                Spacer()
            }

            Text(item.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(white: 0.1))
                .lineLimit(3)
                .multilineTextAlignment(.leading)

            if !item.excerpt.isEmpty {
                Text(item.excerpt)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(white: 0.42))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            if let url = item.coverURL {
                SiteImage(url: url) {
                    Color(white: 0.94)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 168)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            HStack(spacing: 18) {
                stat("bubble.right", item.replies)
                stat("hand.thumbsup", item.likes)
                stat("eye", item.views)
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var avatar: some View {
        Group {
            if let url = item.avatarURL {
                SiteImage(url: url) {
                    Color(white: 0.92)
                }
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color(white: 0.65))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(white: 0.93))
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(Circle())
    }

    private func stat(_ icon: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(value.isEmpty ? "0" : value)
        }
        .font(.system(size: 12))
        .foregroundStyle(Color(white: 0.5))
    }
}
