import SwiftUI

struct PortalView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            ForumTopBar(title: "话题", showsSegment: true, segment: 0, showsBack: false)
            Group {
                if store.portalState == .loading && store.portal.sections.isEmpty && store.portal.notices.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = store.portalState.errorMessage, store.portal.sections.isEmpty {
                    ContentUnavailableView(error, systemImage: "wifi.exclamationmark")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if let notice = store.portal.notices.first {
                                NavigationLink {
                                    ThreadDetailView(tid: notice.id, title: notice.title)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "megaphone.fill")
                                            .foregroundStyle(ForumChrome.blue)
                                        Text(notice.title)
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(Color(white: 0.15))
                                            .lineLimit(1)
                                        Spacer()
                                        Text(notice.dateText)
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color(white: 0.5))
                                    }
                                    .padding(.horizontal, 14)
                                    .frame(height: 44)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                            }
                            ForEach(store.portal.sections) { section in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(section.title)
                                        .font(.system(size: 16, weight: .semibold))
                                        .padding(.horizontal, 4)
                                    ForEach(section.items) { item in
                                        NavigationLink {
                                            ThreadDetailView(tid: item.id, title: item.title)
                                        } label: {
                                            PortalRow(item: item)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        .padding(12)
                    }
                    .background(ForumChrome.page)
                    .refreshable { await store.loadPortal() }
                }
            }
        }
        .background(ForumChrome.page)
        .toolbar(.hidden, for: .navigationBar)
        .task { await store.loadPortal() }
    }
}

private struct PortalRow: View {
    let item: PortalItem

    var body: some View {
        HStack(spacing: 10) {
            SiteImage(url: item.avatarURL) {
                Color(white: 0.92)
            }
            .frame(width: 40, height: 40)
            .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(white: 0.1))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    if !item.author.isEmpty {
                        Text(item.author)
                    }
                    if !item.board.isEmpty {
                        Text(item.board)
                    }
                    if !item.views.isEmpty {
                        Text("查看 \(item.views)")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.5))
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
