import Foundation

@main
struct BodyLinkFixtures {
    static func main() {
        let base = URL(string: "https://sehuatang.org/forum.php?mod=viewthread&tid=3804913&mobile=2")!
        let html = #"<p>前<a href='forum.php?mod=viewthread&amp;tid=42&amp;extra=page%3D1'><b>主题&#x94FE;</b>接</a>中<img file='/one.jpg'>后<a href=../forum-103-1.html>版块</a><a href='javascript:alert(1)'>危险</a><script>秘密</script></p>"#
        let blocks = HTML.orderedContent(in: html, base: base)
        precondition(blocks.count == 3)
        guard case .richText(let first) = blocks[0], case .image = blocks[1], case .richText(let last) = blocks[2] else { fatalError("order") }
        precondition(first.map(\.text).joined().contains("前主题链接中"))
        let link = first.first { $0.href != nil }!
        precondition(link.url!.absoluteString.contains("extra=page%3D1"))
        precondition(SiteRoute.resolve(link.url!) == .thread(42))
        precondition(!last.map(\.text).joined().contains("秘密"))
        for (path, route) in [("thread-42-2-1.html", SiteRoute.thread(42)), ("forum.php?mod=forumdisplay&fid=103", .forum(103)), ("home.php?mod=space&uid=7", .member(7)), ("space-uid-7.html", .member(7))] {
            precondition(SiteRoute.resolve(URL(string: path, relativeTo: base)!.absoluteURL) == route)
        }
        for text in ["javascript:alert(1)", "data:text/html,x", "file:///tmp/x", "tel:123"] { precondition(SiteRoute.resolve(URL(string: text)!) == nil) }
        let outside = URL(string: "https://example.test/forum.php?mod=viewthread&tid=42&x=1#tail")!
        precondition(SiteRoute.resolve(outside) == .web(outside))
        let trick = URL(string: "https://sehuatang.org.evil.test/thread-42-1-1.html")!
        precondition(SiteRoute.resolve(trick) == .web(trick))
        precondition(SiteRoute.resolve(URL(string: "magnet:?xt=urn:btih:test")!) != nil)
        print("PASS body links: text/image order, labels, entity/relative URL, full query, native routes, external in-app, blocked schemes")
    }
}
