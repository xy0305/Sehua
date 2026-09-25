import SwiftUI

/// 跟论坛手机版板块页同一套结构：深色顶栏、左侧分类、右侧板块。
struct ForumHomeView: View {
    @EnvironmentObject var store: AppStore
    @State private var catIndex = 0

    var body: some View {
        VStack(spacing: 0) {
            ForumTopBar(title: "版块", showsSegment: true, showsBack: false)
            if let error = store.forumState.errorMessage, store.categories.isEmpty {
                ContentUnavailableView(error, systemImage: "wifi.exclamationmark")
            } else {
                forumSplit
            }
        }
        .background(ForumChrome.page)
        .toolbar(.hidden, for: .navigationBar)
        .task { await store.loadForums() }
    }

    private var forumSplit: some View {
        let cats = store.categories
        return HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(cats.indices, id: \.self) { i in
                        Button {
                            catIndex = i
                        } label: {
                            Text(cats[i].name)
                                .font(.system(size: 14, weight: i == catIndex ? .semibold : .regular))
                                .foregroundStyle(i == catIndex ? ForumChrome.blue : Color(white: 0.35))
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .background(i == catIndex ? Color.white : ForumChrome.side)
                                .overlay(alignment: .leading) {
                                    if i == catIndex {
                                        Rectangle().fill(ForumChrome.blue).frame(width: 3)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(width: 98)
            .background(ForumChrome.side)

            List(cats[safe: catIndex]?.boards.filter { !$0.isAd } ?? []) { board in
                NavigationLink {
                    ThreadListView(board: board)
                } label: {
                    HStack(alignment: .center, spacing: 10) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(ForumChrome.blue.opacity(0.85))
                            .frame(width: 4, height: 36)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(board.name)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color(white: 0.1))
                            if !board.meta.isEmpty {
                                Text(board.meta)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color(white: 0.55))
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        if board.today > 0 {
                            Text("\(board.today)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(ForumChrome.blue)
                                .padding(.horizontal, 8)
                                .frame(minWidth: 28, minHeight: 22)
                                .background(ForumChrome.blue.opacity(0.1))
                                .clipShape(Capsule())
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(white: 0.75))
                    }
                    .padding(.vertical, 8)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                .listRowSeparator(.hidden)
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                )
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(ForumChrome.page)
        }
    }
}

enum ForumChrome {
    static let bar = Color(red: 0.22, green: 0.24, blue: 0.27)
    static let blue = Color(red: 0.20, green: 0.52, blue: 0.86)
    static let side = Color(red: 0.94, green: 0.94, blue: 0.95)
    static let page = Color(red: 0.96, green: 0.96, blue: 0.97)
    static let line = Color(red: 0.90, green: 0.91, blue: 0.92)
}

struct ForumTopBar: View {
    let title: String
    var showsSegment = false
    var segment = 1
    var showsBack = true
    var onRefresh: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if showsBack {
                    Button { dismiss() } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "chevron.left")
                            Text("返回")
                        }
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear
                }
            }
            .frame(width: 72, alignment: .leading)

            Spacer(minLength: 0)
            if showsSegment {
                HStack(spacing: 0) {
                    NavigationLink {
                        PortalView()
                    } label: {
                        Text("话题")
                            .frame(width: 68, height: 28)
                            .background(segment == 0 ? Color.white : Color.white.opacity(0.16))
                            .foregroundStyle(segment == 0 ? ForumChrome.bar : .white)
                    }
                    .buttonStyle(.plain)
                    NavigationLink {
                        ForumHomeView()
                    } label: {
                        Text("版块")
                            .frame(width: 68, height: 28)
                            .background(segment == 1 ? Color.white : Color.white.opacity(0.16))
                            .foregroundStyle(segment == 1 ? ForumChrome.bar : .white)
                    }
                    .buttonStyle(.plain)
                }
                .font(.system(size: 14))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.7), lineWidth: 1))
            } else {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)

            if let onRefresh {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink {
                    SearchView()
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 48)
        .background(ForumChrome.bar)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension LoadState {
    var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}
