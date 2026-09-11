import SwiftUI

extension View {
    /// 系统导航栏始终钉在顶部：不透明、不随内容滚走、不进大标题折叠。
    func pinnedNavBar() -> some View {
        self
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color(.systemBackground), for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
    }

    func pinnedTabBar() -> some View {
        self
            .toolbar(.visible, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
            .toolbarBackground(Color(.systemBackground), for: .tabBar)
    }
}
