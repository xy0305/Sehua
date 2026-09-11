import SwiftUI

struct SearchView: View {
    @EnvironmentObject var store: AppStore
    @State private var q = ""

    var body: some View {
        VStack(spacing: 0) {
            ChallengeBanner()
            if store.searchState == .loading {
                ProgressView().padding()
            }
            List(store.searchHits) { hit in
                NavigationLink {
                    ThreadDetailView(tid: hit.id, title: hit.title)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(hit.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)
                        if !hit.excerpt.isEmpty {
                            Text(hit.excerpt)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.plain)
        }
        .navigationTitle("搜索")
        .searchable(text: $q, prompt: "搜帖子")
        .onSubmit(of: .search) {
            Task { await store.search(q) }
        }
        .overlay {
            if store.searchHits.isEmpty, store.searchState == .idle, q.isEmpty {
                ContentUnavailableView("搜番号 / 标题", systemImage: "magnifyingglass")
            }
        }
    }
}
