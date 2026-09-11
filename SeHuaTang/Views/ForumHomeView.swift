import SwiftUI

struct ForumHomeView: View {
    @EnvironmentObject var store: AppStore
    @State private var catIndex = 0

    var body: some View {
        VStack(spacing: 0) {
            ChallengeBanner()
            if store.categories.isEmpty {
                ContentUnavailableView("暂无板块", systemImage: "square.grid.2x2")
            } else {
                let cats = store.categories
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(cats.indices, id: \.self) { i in
                            Button {
                                catIndex = i
                            } label: {
                                Text(cats[i].name)
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(i == catIndex ? SiteTheme.accent : Color(.secondarySystemBackground))
                                    .foregroundStyle(i == catIndex ? Color.white : Color.primary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                List(cats[safe: catIndex]?.boards.filter { !$0.isAd } ?? []) { board in
                    NavigationLink {
                        ThreadListView(board: board)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(board.name).font(.body.weight(.medium))
                                if board.today > 0 {
                                    Text("今日 \(board.today)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("色花堂")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await store.loadForums() }
                } label: {
                    if store.forumState == .loading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .task {
            await store.loadForums()
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
