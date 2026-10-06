import SwiftUI

/// Standalone native board directory; the same groups also appear below the portal.
struct ForumHomeView: View {
    @EnvironmentObject var store: AppStore
    @State private var requestedInitialLoad = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                // Directory cards contain variable-height expanded groups;
                // eager layout avoids lazy estimates shifting the scroll offset.
                VStack(alignment: .leading, spacing: 12) {
                    ForumLoadStatus(state: store.forumState, title: "版块") {
                        Task { await store.loadForums() }
                    }
                    ForumDirectory(categories: store.categories)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .refreshable { await store.loadForums() }
        }
        .background(ForumChrome.page)
        .tint(ForumChrome.accent)
        .forumNavigation(title: "全部版块")
        .task {
            guard !requestedInitialLoad else { return }
            requestedInitialLoad = true
            if store.categories == BuiltinForums.categories { await store.loadForums() }
        }
    }
}

struct ForumDirectory: View {
    let categories: [ForumCategory]
    @AppStorage(ForumDirectoryState.storageKey) private var storedExpanded = ""

    private var visibleCategories: [ForumCategory] {
        categories.filter { $0.boards.contains { !$0.isAd } }
    }

    private var expandedIDs: Set<String> {
        ForumDirectoryState.reconciledExpandedIDs(
            ForumDirectoryState.restoredExpandedIDs(stored: storedExpanded),
            categories: visibleCategories
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("版块分区", systemImage: "square.grid.2x2.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ForumChrome.text)
                    .labelStyle(.titleAndIcon)
                Spacer(minLength: 8)
                Text(directorySummary)
                    .font(.caption)
                    .foregroundStyle(ForumChrome.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
            .accessibilityElement(children: .combine)

            if visibleCategories.isEmpty {
                Text("暂无可显示的版块，请下拉刷新。")
                    .font(.subheadline)
                    .foregroundStyle(ForumChrome.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ForumChrome.bar, in: RoundedRectangle(cornerRadius: 16))
            }
            ForEach(visibleCategories) { category in
                ForumCategoryCard(category: category, expanded: expandedIDs.contains(category.id)) {
                    let next = ForumDirectoryState.toggled(expandedIDs, categoryID: category.id)
                    storedExpanded = ForumDirectoryState.persistedValue(for: next)
                }
            }
        }
    }

    private var directorySummary: String {
        let open = expandedIDs.count
        if open == 0 { return "\(visibleCategories.count) 个分区 · 轻点展开" }
        return "已展开 \(open)/\(visibleCategories.count)"
    }
}

private struct ForumCategoryCard: View {
    let category: ForumCategory
    let expanded: Bool
    let toggle: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var boards: [ForumBoard] { category.boards.filter { !$0.isAd } }

    private var categoryIcon: String {
        let name = category.name
        if name.contains("电影") || name.contains("BT") { return "film" }
        if name.contains("在线") || name.contains("视频") { return "play.rectangle" }
        if name.contains("收藏") || name.contains("原档") { return "archivebox" }
        if name.contains("图") { return "photo" }
        if name.contains("文学") || name.contains("小说") { return "book" }
        if name.contains("讨论") { return "text.bubble" }
        return "square.stack.3d.up"
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: categoryIcon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ForumChrome.accent)
                        .frame(width: 32, height: 32)
                        .background(ForumChrome.side, in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(ForumChrome.text)
                            .multilineTextAlignment(.leading)
                        Text(expanded ? "\(boards.count) 个版块" : "已收起")
                            .font(.caption2)
                            .foregroundStyle(ForumChrome.secondary)
                    }
                    Spacer(minLength: 4)
                    Text("\(boards.count)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(ForumChrome.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(ForumChrome.side, in: Capsule())
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ForumChrome.secondary)
                        .frame(width: 18)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(ForumPressStyle())
            .accessibilityLabel(category.name)
            .accessibilityValue(expanded ? "已展开，\(boards.count)个版块" : "已收起，\(boards.count)个版块")
            .accessibilityHint("轻点展开或收起分组")

            if expanded {
                ForEach(boards) { board in
                    ForumChrome.line.frame(height: 0.5).padding(.leading, 16)
                    NavigationLink { ThreadListView(board: board) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "number")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(ForumChrome.accent.opacity(0.85))
                                .frame(width: 22, height: 22)
                                .background(ForumChrome.side, in: RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(board.name)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(ForumChrome.text)
                                    .lineLimit(1)
                                if !board.meta.isEmpty {
                                    Text(board.meta)
                                        .font(.caption2)
                                        .foregroundStyle(ForumChrome.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 4)
                            if board.today > 0 {
                                Text("今日 \(board.today)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(ForumChrome.accent)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(ForumChrome.side, in: Capsule())
                            }
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(ForumChrome.secondary.opacity(0.55))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(ForumPressStyle())
                }
            }
        }
        .background(ForumChrome.bar, in: RoundedRectangle(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
