import Foundation

/// Pure routing shared by inline body links and the link list.
enum SiteRoute: Hashable, Identifiable {
    case thread(Int), forum(Int), member(Int), web(URL), resource(URL)
    var id: String { String(describing: self) }
    static func resolve(_ url: URL) -> SiteRoute? {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "magnet" || scheme == "ed2k" { return .resource(url) }
        guard ["http", "https"].contains(scheme), let host = url.host?.lowercased() else { return nil }
        let local = SiteConfig.mirrors.contains { host == $0 || host.hasSuffix("." + $0) }
        if local {
            let path = url.path.lowercased()
            let items = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems ?? []
            func value(_ key: String) -> String? { items.first { $0.name.lowercased() == key }?.value }
            func positive(_ key: String) -> Int? { guard let s = value(key), let n = Int(s), n > 0 else { return nil }; return n }
            if path.hasSuffix("forum.php"), value("mod")?.lowercased() == "viewthread", let tid = positive("tid") { return .thread(tid) }
            if path.hasSuffix("forum.php"), value("mod")?.lowercased() == "forumdisplay", let fid = positive("fid") { return .forum(fid) }
            if path.hasSuffix("home.php"), value("mod")?.lowercased() == "space", let uid = positive("uid") { return .member(uid) }
            for (pattern, kind) in [(#"^/thread-(\d+)(?:-|\.)"#, 0), (#"^/forum-(\d+)(?:-|\.)"#, 1), (#"^/space-uid-(\d+)(?:-|\.)"#, 2)] {
                if let text = HTML.firstMatch(pattern, in: path), let n = Int(text), n > 0 {
                    return kind == 0 ? .thread(n) : kind == 1 ? .forum(n) : .member(n)
                }
            }
        }
        return .web(url)
    }
}
