import SwiftUI

struct SearchView: View {
    @EnvironmentObject var store: AppStore
    @State private var q = ""

    var body: some View {
        VStack(spacing: 0) {
            ForumTopBar(title: "搜索", showsBack: true)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color(white: 0.5))
                TextField("搜番号 / 标题", text: $q)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit { Task { await store.search(q) } }
                if !q.isEmpty {
                    Button {
                        q = ""
                        store.searchHits = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color(white: 0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Color(white: 0.95))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(12)
            .background(Color.white)

            ScrollView {
                LazyVStack(spacing: 10) {
                    if store.searchState == .loading {
                        ProgressView().padding(.top, 30)
                    } else if let error = store.searchState.errorMessage {
                        ContentUnavailableView(error, systemImage: "wifi.exclamationmark")
                    } else if store.searchHits.isEmpty {
                        ContentUnavailableView("搜番号 / 标题", systemImage: "magnifyingglass")
                            .padding(.top, 40)
                    }
                    ForEach(store.searchHits) { hit in
                        NavigationLink {
                            ThreadDetailView(tid: hit.id, title: hit.title)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(hit.title)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Color(white: 0.1))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                if !hit.excerpt.isEmpty {
                                    Text(hit.excerpt)
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color(white: 0.45))
                                        .lineLimit(2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 20)
            }
            .background(ForumChrome.page)
        }
        .background(ForumChrome.page)
        .toolbar(.hidden, for: .navigationBar)
    }
}
