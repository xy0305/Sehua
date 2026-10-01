import Foundation

// Compile with production sources, NOT -D PARSER_REGRESSION_TESTS.
// swiftc SeHuaTang/Parser/HTML.swift SeHuaTang/Parser/DiscuzParser.swift \
//   SeHuaTang/Models/Models.swift SeHuaTang/Config/SiteConfig.swift \
//   RegressionContent/ContentFixtures.swift -o /tmp/content-fixtures
@main
struct ContentFixtures {
    static func main() {
        let base = URL(string: "https://example.test/forum.php?mod=viewthread&tid=42&mobile=2")!
        func parse(_ html: String) -> ThreadDetail {
            DiscuzParser.parseThreadDetail(html, tid: 42, base: base)
        }
        let mixed = #"""
        <title>测试 - 版块 - 论坛</title>
        <div id='pid10'><div class='message'>第一段<div>嵌套尾段</div></div>
          <div id='postmessage_10'>第二段<img file='/full.jpg' src='/static/image/loading.gif'>图片后尾段</div>
          <div class='message'><div id='postmessage_nested'>嵌套不可重复</div></div></div>
        <div id=post_11><div id='postmessage_11'>回复一</div></div>
        <div id='pid12'><div class='message'>回复二</div></div>
        <div id='post_12'><div class='message'>重复楼层不重复</div></div>
        <div id='post_rate_13'>评分导航</div><footer>非正文</footer>
        """#
        let detail = parse(mixed)
        precondition(detail.posts.map { $0.id } == ["10", "11", "12"])
        precondition(detail.posts[0].plainText.contains("嵌套尾段"))
        precondition(detail.posts[0].plainText.contains("图片后尾段"))
        precondition(detail.posts[0].plainText.components(separatedBy: "嵌套不可重复").count == 2)
        precondition(!detail.posts[0].plainText.contains("回复一"))
        precondition(detail.posts[1].plainText == "回复一")
        precondition(detail.posts[2].plainText == "回复二")
        let unwrapped = parse("<div class='message'>独立首帖</div><div id='postmessage_22'>独立回复</div><footer>导航</footer>")
        precondition(unwrapped.posts.count == 2)
        precondition(unwrapped.posts[0].plainText == "独立首帖")
        precondition(unwrapped.posts[1].plainText == "独立回复")
        precondition(parse("<div>导航</div>").posts.isEmpty)
        let long = String(repeating: "正文长段\n", count: 20000) + "FINAL_SENTINEL"
        precondition(parse("<div id='pid1'><div class='message'>\(long)</div></div>").posts[0].plainText.hasSuffix("FINAL_SENTINEL"))
        let tricky = parse(#"<div id='post_1'><div class='message' data-x='a > b'>开头<!-- </div> --><script>let x='</div>';</script><div>中间</div><p>最后<br>一行</p></div></div>"#)
        precondition(tricky.posts[0].plainText.hasSuffix("最后\n一行"))
        let pieces = HTML.orderedContent(in: "<p>前文</p><img data-src='/one.jpg' src='/static/image/loading.gif'><p>中间</p><img zoomfile='/two.jpg'><p>尾文</p>", base: base)
        precondition(pieces == [.text("前文"), .image(URL(string: "https://example.test/one.jpg")!), .text("中间"), .image(URL(string: "https://example.test/two.jpg")!), .text("尾文")])
        let pager = #"""
        <a href='forum.php?mod=viewthread&amp;tid=42&amp;page=3'>3</a>
        <a href='forum.php?mod=post&amp;action=reply&amp;tid=42&amp;page=2'>回复</a>
        <a href='forum.php?mod=viewthread&amp;tid=99&amp;page=2'>其他主题</a>
        <a href='https://evil.test/forum.php?mod=viewthread&amp;tid=42&amp;page=2'>外站</a>
        <a href='forum.php?mod=viewthread&amp;tid=42&amp;page=2&amp;authorid=7'>只看作者</a>
        <a href='forum.php?mod=viewthread&amp;tid=42&amp;page=1'>上一页</a>
        <a href='forum.php?mod=viewthread&amp;tid=42&amp;page=2&amp;mobile=2'>下一页</a>
        """#
        let next = DiscuzParser.nextThreadPage(in: pager, tid: 42, base: base, page: 1)
        precondition(next.flatMap { HTML.queryInt("page", in: $0.absoluteString) } == 2)
        precondition(DiscuzParser.nextThreadPage(in: pager, tid: 42, base: base, page: 3) == nil)
        precondition(DiscuzParser.nextThreadPage(in: "<a href='forum.php?mod=viewthread&tid=42&page=9'>末页</a>", tid: 42, base: base, page: 1) == nil)
        let page2Base = URL(string: "https://example.test/forum.php?mod=viewthread&tid=42&page=2")!
        let page2 = DiscuzParser.parseThreadDetail("<div class='message'>第二页独立回复</div>", tid: 42, base: page2Base)
        precondition(page2.posts[0].id != unwrapped.posts[0].id)
        let seo = DiscuzParser.nextThreadPage(in: "<a href='thread-42-2-1.html'>下一页</a>", tid: 42, base: base, page: 1)
        precondition(seo?.lastPathComponent == "thread-42-2-1.html")
        print("PASS: production content fixtures (mixed selectors/order, nested dedup, unwrapped posts, long tail, raw text, lazy ordered images, scoped pagination)")
    }
}
