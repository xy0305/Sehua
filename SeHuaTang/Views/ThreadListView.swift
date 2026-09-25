import SwiftUI

struct ThreadListView: View {
    let board: ForumBoard
    @EnvironmentObject var store: AppStore
    @State private var typeID = 0

    var body: some View {
        VStack(spacing: 0) {
            ForumTopBar(title: board.name) {
                Task { await store.loadThreads(fid: board.id, typeid: typeID) }
            }
            if store.threadTypes.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.threadTypes) { t in
                            Button {
                                typeID = t.id
                                Task { await store.loadThreads(fid: board.id, typeid: t.id) }
                            } label: {
                                Text(t.name)
                                    .font(.system(size: 15, weight: typeID == t.id ? .semibold : .regular))
                                    .foregroundStyle(typeID == t.id ? ForumChrome.blue : Color(white: 0.25))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                                    .overlay(alignment: .bottom) {
                                        if typeID == t.id {
                                            Rectangle().fill(ForumChrome.blue).frame(height: 2)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }

            List {
                ForEach(store.threads) { item in
                    NavigationLink {
                        ThreadDetailView(tid: item.id, title: item.title)
                    } label: {
                        ThreadRow(item: item)
                    }
                    .onAppear {
                        if item.id == store.threads.last?.id {
                            Task { await store.loadMore() }
                        }
                    }
                }
                if store.threadState == .loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            }
            .listStyle(.plain)
            .refreshable {
                await store.loadThreads(fid: board.id, typeid: typeID)
            }
        }
        .navigationTitle(board.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await store.loadThreads(fid: board.id)
        }
    }
}

struct ThreadRow: View {
    let item: ThreadItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let url = item.coverURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    default:
                        Color(.tertiarySystemFill)
                    }
                }
                .frame(width: 72, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if item.isSticky {
                        Text("顶")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(SiteTheme.accent.opacity(0.15))
                            .foregroundStyle(SiteTheme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                }
                if !item.excerpt.isEmpty {
                    Text(item.excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 10) {
                    if !item.author.isEmpty { Text(item.author) }
                    if !item.dateText.isEmpty { Text(item.dateText) }
                    if !item.views.isEmpty { Text("\(item.views) 看") }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}
