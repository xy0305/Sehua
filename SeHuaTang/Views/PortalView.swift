import SwiftUI

/// Native landing page: portal discussions followed by collapsible board groups.
struct PortalView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject var store: AppStore
    @State private var showsAllDiscussions = false
    @State private var requestedInitialLoad = false

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
                // These are a handful of composite cards, not individual rows.
                // Eager layout keeps their real heights instead of LazyVStack's
                // estimates changing when the tall directory enters the viewport.
                VStack(alignment: .leading, spacing: 14) {
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
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .refreshable { await reload() }
        }
        .background(ForumChrome.page)
        .tint(ForumChrome.accent)
        .forumNavigation(title: "色花堂")
        .task {
            guard !requestedInitialLoad else { return }
            requestedInitialLoad = true
            // Returning from a detail must not replace the page being read.
            if store.portal.sections.isEmpty { await store.loadPortal() }
            if store.categories == BuiltinForums.categories { await store.loadForums() }
        }
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
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ForumChrome.accent)
                    .frame(width: 30, height: 30)
                    .background(ForumChrome.side, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text("公告")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(ForumChrome.accent)
                    Text(notice.title)
                        .font(.system(size: 14, weight: .medium))
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
                    .foregroundStyle(ForumChrome.secondary.opacity(0.7))
            }
            .padding(12)
            .background(ForumChrome.bar, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(ForumChrome.accent.opacity(0.16), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var discussionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ForumChrome.accent)
                    .frame(width: 28, height: 28)
                    .background(ForumChrome.side, in: RoundedRectangle(cornerRadius: 8))
                Text("最新讨论")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ForumChrome.text)
                Spacer(minLength: 8)
                Text(discussions.isEmpty ? "社区动态" : "\(discussions.count) 条")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(ForumChrome.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(ForumChrome.side, in: Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if discussions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.portalState == .loading ? "正在获取社区讨论" : "暂无讨论内容")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(ForumChrome.text)
                    Text("下拉刷新，或先展开下方版块。")
                        .font(.caption)
                        .foregroundStyle(ForumChrome.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 16)
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
            SiteImage(url: item.avatarURL, preservesIntrinsicAspectRatio: false) {
                ZStack {
                    ForumChrome.side
                    Image(systemName: "person.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(ForumChrome.accent.opacity(0.7))
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
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
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}
