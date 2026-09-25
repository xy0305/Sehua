import Foundation

struct ThreadItem: Identifiable, Hashable {
    let id: Int
    var title: String
    var excerpt: String
    var author: String
    var authorID: Int?
    var avatarURL: URL?
    var coverURL: URL?
    var dateText: String
    var replies: String
    var likes: String
    var views: String
    var isSticky: Bool
    var fid: Int?
}

struct ThreadType: Identifiable, Hashable {
    let id: Int
    let name: String
}

struct ThreadListPage {
    var threads: [ThreadItem]
    var types: [ThreadType]
    var page: Int
    var hasNext: Bool
    var boardName: String
}

struct ThreadAttachment: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
    var isMagnet: Bool { url.scheme?.lowercased() == "magnet" }
    var isED2K: Bool { url.scheme?.lowercased() == "ed2k" }
}

struct ThreadPost: Identifiable, Hashable {
    let id: String
    var author: String
    var authorID: Int?
    var avatarURL: URL?
    var dateText: String
    var htmlBody: String
    var plainText: String
    var images: [URL]
}

struct ThreadDetail {
    var tid: Int
    var title: String
    var boardName: String = ""
    var fid: Int?
    var posts: [ThreadPost]
    var magnets: [ThreadAttachment]
    var attachments: [ThreadAttachment]
    var images: [URL]
}

struct SearchHit: Identifiable, Hashable {
    let id: Int
    var title: String
    var excerpt: String
    var board: String
    var author: String
    var dateText: String
}

struct SiteNotice: Identifiable, Hashable {
    let id: Int
    var title: String
    var dateText: String
}

struct PortalSection: Identifiable, Hashable {
    let id: String
    var title: String
    var moreHref: String
    var items: [PortalItem]
}

struct PortalItem: Identifiable, Hashable {
    let id: Int
    var title: String
    var author: String
    var board: String
    var views: String
    var avatarURL: URL?
}

struct PortalPage {
    var notices: [SiteNotice]
    var sections: [PortalSection]
}

enum LoadState: Equatable {
    case idle
    case loading
    case failed(String)
}
