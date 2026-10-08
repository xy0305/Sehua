import Foundation

@main
struct SearchPaginationFixtures {
    static func main() {
        let base = URL(string: "https://www.sehuatang.org/search.php?mod=forum")!
        // Actual mobile site's query order; session ID/signature and keyword replaced.
        let next = "search.php?mod=forum&searchid=0&searchmd5=REDACTED&orderby=lastpost&ascdesc=desc&searchsubmit=yes&kw=REDACTED&page=2&mobile=2"
        let html = "<a href=\"\(next)\">下一页</a>"
        let url = DiscuzParser.searchNextURL(html, baseURL: base, page: 1)!
        precondition(url.absoluteString.contains("searchmd5=REDACTED"))
        precondition(HTML.queryInt("page", in: url.absoluteString) == 2)
        precondition(DiscuzParser.searchNextURL(html, baseURL: base, page: 2) == nil)
        let reordered = "<a class='next' href='search.php?page=3&amp;mod=forum&amp;searchid=0&amp;searchmd5=REDACTED'>下一页</a>"
        precondition(HTML.queryInt("page", in: DiscuzParser.searchNextURL(reordered, baseURL: url, page: 2)!.absoluteString) == 3)
        for bad in ["https://evil.example/search.php?mod=forum&searchid=0&page=2", "http://www.sehuatang.org/search.php?mod=forum&searchid=0&page=2", "forum.php?mod=viewthread&tid=123&page=2", "search.php?mod=forum&page=2", "search.php?mod=forum&searchid=0&page=2&page=3", "search.php?mod=forum&searchid=0&page=01", "search.php?mod=forum&searchid=0&page=-1"] {
            precondition(DiscuzParser.searchNextURL("<a href='\(bad)'>下一页</a>", baseURL: base, page: 1) == nil)
        }
        var seen = Set<Int>()
        var total = 0
        for page in 1...3 {
            let first = (page - 1) * 30 + 1
            let hits = (first..<(first + 30)).map { "<a class='result' href='forum.php?mod=viewthread&amp;tid=\($0)'>Fixture \($0)</a>" }.joined()
            let parsed = DiscuzParser.parseSearch(hits)
            total += parsed.hits.filter { seen.insert($0.id).inserted }.count
        }
        precondition(total == 90)
        // Overlap never decides pagination exhaustion: the valid server cursor does.
        let overlap = DiscuzParser.parseSearch("<a href='forum.php?tid=1'>Fixture</a>" + html)
        precondition(overlap.hits.count == 1)
        precondition(DiscuzParser.searchNextURL(html, baseURL: base, page: 1) != nil)
        precondition(DiscuzParser.searchNextURL("", baseURL: base, page: 3) == nil)
        print("Search pagination production-parser fixtures passed (90 unique synthetic IDs; live counts separately recorded).")
    }
}
