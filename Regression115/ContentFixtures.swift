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
        let smileyHTML = "前文<img src='static/image/smiley/default/smile.gif?v=2' width='24' height='20'>后文<blockquote>引用<img smilieid='7' src='/custom/animated.gif' width='200' height='100'></blockquote><img src='/preview.jpg' width='16' height='16'><img src='/static/image/decor.gif'><img src='/preview.png?fake=/static/image/smiley/default/smile.gif'><img class='smilie-extra' src='/small.png'><img class='smilie' src='/custom/icon.gif'><img src='/static/image/smiley/default/x.gif' width='NaN' height='-2'>"
        let smileyPost = parse("<div id='pid1'><div class='message'>\(smileyHTML)</div></div>").posts[0]
        let smileyBlocks = HTML.orderedContent(in: smileyPost.htmlBody, base: base)
        let smileys = smileyBlocks.compactMap { block -> HTML.Emoticon? in
            if case .emoticon(let item) = block { return item }; return nil
        }
        let media = smileyBlocks.compactMap { block -> URL? in
            if case .image(let url) = block { return url }; return nil
        }
        precondition(smileys.count == 4 && media.count == 4)
        precondition(smileyBlocks.prefix(3).count == 3)
        guard case .text("前文") = smileyBlocks[0], case .emoticon = smileyBlocks[1], case .text("后文") = smileyBlocks[2] else { fatalError("smiley text order") }
        precondition(smileys[0].width == 24 && smileys[0].height == 20 && smileys[0].url.query == "v=2")
        precondition(smileys[1].width == 32 && smileys[1].height == 16)
        precondition(smileys[2].width == 28 && smileys[3].height == 28)
        precondition(smileys.allSatisfy { max($0.width, $0.height) <= 32 })
        precondition(!smileyPost.images.contains { $0.path == "/custom/animated.gif" || $0.path == "/custom/icon.gif" })
        precondition(media.map(\.path) == ["/preview.jpg", "/static/image/decor.gif", "/preview.png", "/small.png"])
        print("PASS: production semantic smiley classification, relative/query URLs, quoted GIF, bounded render size, dimensions, non-smiley decorations/previews, text order")
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
        let ratingsHTML = #"""
        <dl class="rate" id="ratelog_10"><dt>评分</dt><dd><div id="post_rate_10"></div><table class="ratl">
        <tr><th>参与人数 <span>133</span></th><th>金钱 <b>+66</b></th><th>评分 <b>+236</b></th><th>收起 理由</th></tr>
        <tr><td><a href="home.php?mod=space&amp;uid=7"><img src="/avatar7.jpg"></a><a href="home.php?mod=space&amp;uid=7">用户七</a></td><td></td><td>+ 2</td><td>很给力!<br>第二行</td></tr>
        <tr><td><a href="space-uid-8.html">用户八</a></td><td>+1</td><td></td><td></td></tr>
        </table></dd></dl>
        """#
        let ordinary = "<table><tr><td>真正正文表格 评分说明<img src='/body.jpg'></td></tr></table>"
        let inside = parse("<div id='pid10'><div class='message'>前文\(ordinary)\(ratingsHTML)<p>尾文</p><div class='locked'>如果您要查看本帖隐藏内容请回复</div></div></div>")
        let p = inside.posts[0]
        precondition(p.images.map { $0.lastPathComponent } == ["body.jpg"])
        precondition(inside.images == p.images)
        precondition(p.htmlBody.contains(ordinary) && p.plainText.contains("真正正文表格") && p.plainText.contains("尾文"))
        precondition(p.plainText.contains("隐藏内容请回复") && !p.plainText.contains("参与人数"))
        precondition(p.ratings?.participants == "133" && p.ratings?.totals == ["金钱 +66", "评分 +236"])
        precondition(p.ratings?.entries.count == 2 && p.ratings?.entries[0].uid == 7)
        precondition(p.ratings?.entries[0].name == "用户七" && p.ratings?.entries[0].reason == "很给力!\n第二行")
        precondition(p.ratings?.entries[0].avatarURL?.lastPathComponent == "avatar7.jpg")
        let outside = parse("<div id='pid10'><div class='message'>\(ordinary)</div>\(ratingsHTML)</div>")
        precondition(outside.posts[0].ratings == p.ratings)
        precondition(outside.posts[0].images == p.images)
        let missing = parse("<div id='pid1'><div class='message'>正文<dl id='ratelog_1'><table class='ratl'><tr><td>未知结构<img src='/avatar.jpg'></td></tr></table></dl></div></div>")
        precondition(missing.posts[0].ratings != nil && missing.posts[0].ratings?.participants == nil)
        precondition(missing.posts[0].ratings?.entries.isEmpty == true && missing.posts[0].images.isEmpty)
        precondition(missing.posts[0].plainText == "正文")
        precondition(parse("<div class='message'>\(ordinary)\(ratingsHTML)</div>").posts[0].ratings?.participants == "133")
        print("PASS: rating boundary fixtures (live mobile DL/table shape, summary, users, multiline reason, avatars excluded, sibling/nested/unwrapped, missing fields, ordinary table, permission notice)")
        print("PASS: production content fixtures (mixed selectors/order, nested dedup, unwrapped posts, long tail, raw text, lazy ordered images, scoped pagination)")
    }
}
