import SwiftUI

enum SiteTheme {
    static let accent = Color(red: 0.91, green: 0.31, blue: 0.55)
    static let rose = Color(red: 0.86, green: 0.18, blue: 0.48)
}

enum SiteConfig {
    static let cookiePrefix = "cPNj_2132_"
    static let ageCookieName = "_safe"
    static let defaultHost = "www.sehuatang.org"
    static let mirrors = [
        "www.sehuatang.org",
        "sehuatang.org"
    ]
    static let adFIDs: Set<Int> = [148, 149]
    static let adKeywords = [
        "赌场", "棋牌", "百家乐", "葡京", "招代理", "鲍鱼盒子", "爆奖",
        "红包雨", "开元", "凤凰国际", "必发国际", "亚博", "大發", "大发",
        "注册送", "看黄片", "PG娱乐", "PG电子"
    ]

    static func isAdText(_ text: String) -> Bool {
        adKeywords.contains { text.contains($0) }
    }
}

struct ForumCategory: Identifiable, Hashable {
    let id: String
    let name: String
    let boards: [ForumBoard]
}

struct ForumBoard: Identifiable, Hashable {
    let id: Int
    let name: String
    var today: Int
    var meta: String = ""
    var isAd: Bool { SiteConfig.adFIDs.contains(id) }
}

enum BuiltinForums {
    static let categories: [ForumCategory] = [
        ForumCategory(id: "bt", name: "原创BT电影", boards: [
            .init(id: 2, name: "国产原创", today: 0),
            .init(id: 36, name: "亚洲无码原创", today: 0),
            .init(id: 37, name: "亚洲有码原创", today: 0),
            .init(id: 103, name: "高清中文字幕", today: 0),
            .init(id: 107, name: "三级写真", today: 0),
            .init(id: 160, name: "VR视频区", today: 0),
            .init(id: 104, name: "素人有码系列", today: 0),
            .init(id: 38, name: "欧美无码", today: 0),
            .init(id: 151, name: "4K原版", today: 0),
            .init(id: 152, name: "韩国主播", today: 0),
            .init(id: 39, name: "动漫原创", today: 0)
        ]),
        ForumCategory(id: "online", name: "在线视频区", boards: [
            .init(id: 41, name: "国产自拍", today: 0),
            .init(id: 109, name: "中文字幕", today: 0),
            .init(id: 42, name: "日韩无码", today: 0),
            .init(id: 43, name: "日韩有码", today: 0),
            .init(id: 44, name: "欧美风情", today: 0),
            .init(id: 45, name: "卡通动漫", today: 0),
            .init(id: 46, name: "剧情三级", today: 0)
        ]),
        ForumCategory(id: "archive", name: "原档收藏", boards: [
            .init(id: 145, name: "自提字幕区", today: 0),
            .init(id: 146, name: "自译字幕区", today: 0),
            .init(id: 121, name: "字幕分享区", today: 0),
            .init(id: 159, name: "新作区", today: 0)
        ]),
        ForumCategory(id: "pic", name: "色花图片", boards: [
            .init(id: 155, name: "原创自拍区", today: 0),
            .init(id: 125, name: "转贴自拍", today: 0),
            .init(id: 50, name: "华人街拍区", today: 0),
            .init(id: 48, name: "亚洲性爱", today: 0),
            .init(id: 49, name: "欧美性爱", today: 0),
            .init(id: 117, name: "卡通动漫", today: 0),
            .init(id: 165, name: "套图下载", today: 0)
        ]),
        ForumCategory(id: "novel", name: "色花文学", boards: [
            .init(id: 154, name: "原创小说", today: 0),
            .init(id: 135, name: "乱伦人妻", today: 0),
            .init(id: 137, name: "青春校园", today: 0),
            .init(id: 138, name: "武侠虚幻", today: 0),
            .init(id: 136, name: "激情都市", today: 0),
            .init(id: 139, name: "TXT小说下载", today: 0)
        ]),
        ForumCategory(id: "talk", name: "综合讨论区", boards: [
            .init(id: 95, name: "综合讨论区", today: 0),
            .init(id: 166, name: "AI专区", today: 0),
            .init(id: 141, name: "网友原创区", today: 0),
            .init(id: 142, name: "转帖交流区", today: 0),
            .init(id: 143, name: "求片问答悬赏区", today: 0),
            .init(id: 96, name: "投诉建议区", today: 0),
            .init(id: 97, name: "资源出售区", today: 0),
            .init(id: 157, name: "投稿送邀请码", today: 0)
        ])
    ]
}
