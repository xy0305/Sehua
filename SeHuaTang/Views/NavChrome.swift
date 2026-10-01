import SwiftUI

/// Shared native forum palette. Keep the legacy `blue` name for existing callers.
enum ForumChrome {
    static let accent = SiteTheme.accent
    static let blue = accent
    static let bar = Color(uiColor: .secondarySystemGroupedBackground)
    static let side = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.24, green: 0.14, blue: 0.19, alpha: 1)
            : UIColor(red: 0.98, green: 0.94, blue: 0.96, alpha: 1)
    })
    static let page = Color(uiColor: .systemGroupedBackground)
    static let line = Color(uiColor: .separator).opacity(0.4)
    static let text = Color.primary
    static let secondary = Color.secondary
}

struct ForumTopBar: View {
    let title: String
    var showsSegment = false
    var segment = 1
    var showsBack = true
    var onRefresh: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 8) {
            if showsBack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("返回")
                Text(title)
                    .font(.headline)
                    .foregroundStyle(ForumChrome.text)
                    .lineLimit(1)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "camera.macro")
                        .font(.system(size: 24, weight: .semibold))
                    Text("色花堂")
                        .font(.system(size: 23, weight: .bold, design: .rounded))
                }
                .foregroundStyle(ForumChrome.accent)
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
            if let onRefresh {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("刷新")
            } else {
                NavigationLink { SearchView() } label: {
                    Image(systemName: "magnifyingglass")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("搜索帖子")
            }
            if !showsBack {
                NavigationLink { MineView() } label: {
                    Image(systemName: "person.crop.circle")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("账户与登录")
            }
        }
        .font(.system(size: 20, weight: .medium))
        .foregroundStyle(ForumChrome.accent)
        .buttonStyle(.plain)
        .padding(.horizontal, showsBack ? 4 : 16)
        .frame(minHeight: 58)
        .background(ForumChrome.bar)
        .overlay(alignment: .bottom) { ForumChrome.line.frame(height: 0.5) }
    }
}

/// Errors remain visible even while built-in or previously loaded data is usable.
struct ForumLoadStatus: View {
    let state: LoadState
    let title: String
    var retry: () -> Void

    var body: some View {
        if state == .loading {
            HStack(spacing: 10) {
                ProgressView().tint(ForumChrome.accent)
                Text("正在加载\(title)…")
                    .font(.subheadline)
                    .foregroundStyle(ForumChrome.secondary)
                Spacer()
            }
            .padding(14)
            .background(ForumChrome.bar, in: RoundedRectangle(cornerRadius: 14))
        } else if let error = state.errorMessage {
            VStack(alignment: .leading, spacing: 10) {
                Label("\(title)加载失败", systemImage: "wifi.exclamationmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ForumChrome.text)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(ForumChrome.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("重试", action: retry)
                        .buttonStyle(.borderedProminent)
                    NavigationLink {
                        LoginWebView(
                            url: WebSession.shared.url("forum.php?forumlist=1&mobile=2"),
                            title: "登录 / 完成验证"
                        )
                    } label: {
                        Label("登录 / 完成验证", systemImage: "checkmark.shield")
                    }
                    .buttonStyle(.bordered)
                }
                .font(.caption.weight(.medium))
                .tint(ForumChrome.accent)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ForumChrome.bar, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

extension View {
    func pinnedNavBar() -> some View {
        self
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(ForumChrome.bar, for: .navigationBar)
    }

    func pinnedTabBar() -> some View {
        self
            .toolbar(.visible, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
            .toolbarBackground(ForumChrome.bar, for: .tabBar)
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
