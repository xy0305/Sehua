import SwiftUI

/// Standalone native board directory; the same groups also appear below the portal.
struct ForumHomeView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForumLoadStatus(state: store.forumState, title: "版块") {
                        Task { await store.loadForums() }
                    }
                    ForumDirectory(categories: store.categories)
                }
                .padding(16)
            }
            .refreshable { await store.loadForums() }
        }
        .background(ForumChrome.page)
        .tint(ForumChrome.accent)
        .forumNavigation(title: "全部版块")
        .task { await store.loadForums() }
    }
}

struct ForumDirectory: View {
    let categories: [ForumCategory]

    private var visibleCategories: [ForumCategory] {
        categories.filter { $0.boards.contains { !$0.isAd } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("版块分区", systemImage: "square.grid.2x2")
                    .font(.headline)
                    .foregroundStyle(ForumChrome.text)
                Spacer()
                Text("点击分组展开 / 收起")
                    .font(.caption)
                    .foregroundStyle(ForumChrome.secondary)
            }
            .padding(.horizontal, 2)

            if visibleCategories.isEmpty {
                Text("暂无可显示的版块，请下拉刷新。")
                    .font(.subheadline)
                    .foregroundStyle(ForumChrome.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ForumChrome.bar, in: RoundedRectangle(cornerRadius: 16))
            }
            ForEach(visibleCategories) { category in
                ForumCategoryCard(
                    category: category,
                    initiallyExpanded: category.id == visibleCategories.first?.id
                )
            }
        }
    }
}

private struct ForumCategoryCard: View {
    let category: ForumCategory
    @State private var expanded: Bool

    init(category: ForumCategory, initiallyExpanded: Bool) {
        self.category = category
        _expanded = State(initialValue: initiallyExpanded)
    }

    private var boards: [ForumBoard] { category.boards.filter { !$0.isAd } }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(ForumChrome.accent)
                        .frame(width: 32, height: 32)
                        .background(ForumChrome.side, in: RoundedRectangle(cornerRadius: 9))
                    Text(category.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(ForumChrome.text)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    Text("\(boards.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(ForumChrome.secondary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ForumChrome.accent)
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(category.name)
            .accessibilityValue(expanded ? "已展开，\(boards.count)个版块" : "已收起，\(boards.count)个版块")
            .accessibilityHint("轻点展开或收起分组")

            if expanded {
                ForEach(boards) { board in
                    ForumChrome.line.frame(height: 0.5).padding(.leading, 16)
                    NavigationLink { ThreadListView(board: board) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 17))
                                .foregroundStyle(ForumChrome.accent.opacity(0.8))
                                .frame(width: 30)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(board.name)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(ForumChrome.text)
                                if !board.meta.isEmpty {
                                    Text(board.meta)
                                        .font(.caption)
                                        .foregroundStyle(ForumChrome.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 4)
                            if board.today > 0 {
                                Text("今日 \(board.today)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(ForumChrome.accent)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(ForumChrome.side, in: Capsule())
                            }
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(ForumChrome.secondary.opacity(0.6))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                        .frame(minHeight: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(ForumChrome.bar, in: RoundedRectangle(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
