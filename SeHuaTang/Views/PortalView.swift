import SwiftUI

/// Native landing page: portal discussions followed by collapsible board groups.
struct PortalView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject var store: AppStore
    @State private var showsAllDiscussions = false

    // The portal supplies its own ordering; don't mutate the shared thread-list store.
    private var discussions: [PortalItem] {
        let sections = store.portal.sections
        let latest = sections.filter { $0.title.contains("最新") }
        let remaining = sections.filter { !$0.title.contains("最新") }
        var seen = Set<Int>()
        return (latest + remaining).flatMap(\.items).filter { seen.insert($0.id).inserted }
    }

    private var visibleDiscussions: [PortalItem] {
        showsAllDiscussions ? discussions : Array(discussions.prefix(8))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForumLoadStatus(state: store.portalState, title: "讨论") {
                        Task { await store.loadPortal() }
                    }
                    if let notice = store.portal.notices.first {
                        noticeCard(notice)
                    }
                    discussionCard
                    ForumLoadStatus(state: store.forumState, title: "版块") {
                        Task { await store.loadForums() }
                    }
                    ForumDirectory(categories: store.categories)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 24)
            }
            .refreshable { await reload() }
        }
        .background(ForumChrome.page)
        .tint(ForumChrome.accent)
        .forumNavigation(title: "色花堂")
        .task { await reload() }
    }

    private func reload() async {
        await store.loadPortal()
        await store.loadForums()
    }

    private func noticeCard(_ notice: SiteNotice) -> some View {
        NavigationLink {
            ThreadDetailView(tid: notice.id, title: notice.title)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "megaphone.fill")
                    .foregroundStyle(ForumChrome.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(notice.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ForumChrome.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !notice.dateText.isEmpty {
                        Text(notice.dateText)
                            .font(.caption2)
                            .foregroundStyle(ForumChrome.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ForumChrome.secondary)
            }
            .padding(14)
            .background(ForumChrome.bar, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var discussionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .foregroundStyle(ForumChrome.accent)
                Text("最新讨论")
                    .font(.headline)
                    .foregroundStyle(ForumChrome.text)
                Spacer()
                Text("社区动态")
                    .font(.caption)
                    .foregroundStyle(ForumChrome.secondary)
            }
            .padding(16)

            if discussions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.portalState == .loading ? "正在获取社区讨论…" : "暂无讨论内容")
                        .font(.subheadline)
                    Text("下拉刷新，或先浏览下方版块。")
                        .font(.caption)
                }
                .foregroundStyle(ForumChrome.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            } else {
                ForEach(visibleDiscussions) { item in
                    ForumChrome.line.frame(height: 0.5).padding(.horizontal, 16)
                    NavigationLink {
                        ThreadDetailView(tid: item.id, title: item.title)
                    } label: {
                        PortalRow(item: item)
                    }
                    .buttonStyle(.plain)
                }
                if discussions.count > 8 {
                    ForumChrome.line.frame(height: 0.5)
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { showsAllDiscussions.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Text(showsAllDiscussions ? "收起讨论" : "查看全部讨论（\(discussions.count)）")
                            Image(systemName: showsAllDiscussions ? "chevron.up" : "chevron.down")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ForumChrome.accent)
                        .frame(maxWidth: .infinity, minHeight: 46)
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

private struct PortalRow: View {
    let item: PortalItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SiteImage(url: item.avatarURL) {
                ZStack {
                    ForumChrome.side
                    Image(systemName: "person.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(ForumChrome.accent.opacity(0.65))
                }
            }
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ForumChrome.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 7) {
                    if !item.board.isEmpty {
                        Text(item.board).foregroundStyle(ForumChrome.accent)
                    }
                    if !item.author.isEmpty {
                        Text(item.author).foregroundStyle(ForumChrome.secondary)
                    }
                    Spacer(minLength: 0)
                    if !item.views.isEmpty {
                        Label(item.views, systemImage: "eye")
                            .foregroundStyle(ForumChrome.secondary)
                    }
                }
                .font(.system(size: 11))
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}
