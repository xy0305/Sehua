import SwiftUI

struct SearchView: View {
    @EnvironmentObject var store: AppStore
    @State private var q = ""
    @State private var submittedQuery = ""
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    private var trimmedQuery: String {
        q.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                searchHeader
                statusSection
                if !store.searchHits.isEmpty { resultsSection }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(ForumChrome.page)
        .tint(ForumChrome.accent)
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(ForumChrome.bar, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("搜索帖子").font(.title2.bold()).foregroundStyle(ForumChrome.text)
            Text("输入番号或标题，在站内查找内容。")
                .font(.subheadline).foregroundStyle(ForumChrome.secondary)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(ForumChrome.accent)
                TextField("搜番号 / 标题", text: $q)
                    .foregroundStyle(ForumChrome.text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .onSubmit { submitSearch() }
                if !q.isEmpty {
                    Button(action: clearSearch) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(ForumChrome.secondary)
                            .frame(minWidth: 32, minHeight: 44)
                    }
                    .buttonStyle(.plain).accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, 12).frame(minHeight: 48)
            .background(ForumChrome.page, in: RoundedRectangle(cornerRadius: 12))
            Button(action: submitSearch) {
                Text("搜索").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(trimmedQuery.isEmpty)
        }
        .padding(16)
        .background(ForumChrome.bar, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder private var statusSection: some View {
        if store.searchState == .loading && store.searchHits.isEmpty {
            HStack(spacing: 10) {
                ProgressView().tint(ForumChrome.accent)
                Text("正在搜索…").foregroundStyle(ForumChrome.secondary)
                Spacer()
            }
            .padding(16).background(ForumChrome.bar, in: RoundedRectangle(cornerRadius: 16))
        } else if let error = store.searchState.errorMessage, store.searchHits.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label("搜索未完成", systemImage: "wifi.exclamationmark")
                    .font(.headline).foregroundStyle(ForumChrome.text)
                Text(error).font(.subheadline).foregroundStyle(ForumChrome.secondary)
                Button("重试") { retrySearch() }.buttonStyle(.bordered)
                NavigationLink { MineView() } label: {
                    Label("需要登录或验证？前往我的", systemImage: "checkmark.shield")
                        .font(.subheadline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16).background(ForumChrome.bar, in: RoundedRectangle(cornerRadius: 16))
        } else if store.searchHits.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 32)).foregroundStyle(ForumChrome.accent)
                Text(submittedQuery.isEmpty ? "发现你感兴趣的帖子" : "本次未返回匹配帖子")
                    .font(.headline).foregroundStyle(ForumChrome.text)
                Text(submittedQuery.isEmpty ? "输入关键词开始搜索。" : "试试其他关键词；如遇站点验证，请到「我的」完成验证后重试。")
                    .font(.subheadline).foregroundStyle(ForumChrome.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(24)
            .background(ForumChrome.bar, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("已加载 \(store.searchHits.count) 条")
                .font(.subheadline.weight(.medium)).foregroundStyle(ForumChrome.secondary)
            LazyVStack(spacing: 12) {
                ForEach(store.searchHits) { hit in
                    NavigationLink {
                        ThreadDetailView(tid: hit.id, title: hit.title)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(hit.title).font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(ForumChrome.text).lineLimit(2)
                                if !hit.excerpt.isEmpty {
                                    Text(hit.excerpt).font(.subheadline)
                                        .foregroundStyle(ForumChrome.secondary).lineLimit(2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                .foregroundStyle(ForumChrome.accent)
                        }
                        .multilineTextAlignment(.leading).padding(16)
                        .background(ForumChrome.bar, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if hit.id == store.searchHits.last?.id { loadMore() }
                    }
                }
            }
            if store.searchHasNext && store.searchState == .idle {
                Color.clear.frame(height: 1).id(store.searchPage).onAppear { loadMore() }
            }
            Group {
                if store.searchState == .loading {
                    HStack(spacing: 8) {
                        ProgressView().tint(ForumChrome.accent)
                        Text("正在加载更多…").font(.footnote).foregroundStyle(ForumChrome.secondary)
                    }
                } else if let error = store.searchState.errorMessage {
                    VStack(spacing: 8) {
                        Text(error).font(.footnote).foregroundStyle(ForumChrome.secondary)
                        Button("重试加载", action: retrySearch).font(.footnote).buttonStyle(.bordered)
                    }
                } else {
                    Text(store.searchHasNext ? "上滑继续加载" : "已加载全部搜索结果")
                        .font(.footnote).foregroundStyle(ForumChrome.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 56)
        }
    }

    private func submitSearch() {
        guard !trimmedQuery.isEmpty else { return }
        searchFocused = false
        searchTask?.cancel()
        submittedQuery = trimmedQuery
        let query = trimmedQuery
        searchTask = Task { await store.search(query) }
    }

    private func loadMore() {
        guard store.searchHasNext, store.searchState != .loading else { return }
        searchTask?.cancel()
        searchTask = Task { await store.loadMoreSearch() }
    }

    private func retrySearch() {
        guard store.searchState != .loading else { return }
        searchTask?.cancel()
        searchTask = Task { await store.retrySearch() }
    }

    private func clearSearch() {
        searchTask?.cancel()
        q = ""
        submittedQuery = ""
        searchTask = Task { await store.search("") }
    }
}
