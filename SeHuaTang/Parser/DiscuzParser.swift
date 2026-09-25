import Foundation

enum DiscuzParser {
    static func parsePortal(_ html: String, base: URL) -> PortalPage {
        var notices: [SiteNotice] = []
        var seenNotice = Set<Int>()
        if let box = HTML.firstMatch(#"class="n5_ggmk[\s\S]*?</ul>"#, in: html) {
            let hrefs = HTML.allMatches(#"<a href="([^"]*tid=\d+[^"]*)"[^>]*>([\s\S]*?)</a>"#, in: box, group: 1)
            let titles = HTML.allMatches(#"<a href="([^"]*tid=\d+[^"]*)"[^>]*>([\s\S]*?)</a>"#, in: box, group: 2)
            let dates = HTML.allMatches(#"<i>([^<]*)</i>"#, in: box, group: 1)
            for (i, pair) in zip(hrefs, titles).enumerated() {
                guard let tid = HTML.queryInt("tid", in: pair.0), seenNotice.insert(tid).inserted else { continue }
                let title = HTML.stripTags(pair.1)
                if title.isEmpty || SiteConfig.isAdText(title) { continue }
                let date = i < dates.count ? dates[i] : ""
                notices.append(SiteNotice(id: tid, title: title, dateText: date))
            }
        }

        var sections: [PortalSection] = []
        let blocks = html.components(separatedBy: "n5_hdlbmk")
        for (index, raw) in blocks.dropFirst().enumerated() {
            let block = String(raw.prefix(20000))
            let title = HTML.stripTags(HTML.firstMatch(#"class="n5_tbzxbt[^"]*"[^>]*>([\s\S]*?)</div>"#, in: block) ?? "")
                .replacingOccurrences(of: "更多", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty || SiteConfig.isAdText(title) { continue }
            let more = HTML.firstMatch(#"<a href="([^"]*)"[^>]*>更多</a>"#, in: block) ?? ""
            var items: [PortalItem] = []
            var seen = Set<Int>()
            let lis = block.components(separatedBy: "<li")
            for li in lis.dropFirst() {
                let card = "<li" + li
                guard let href = HTML.firstMatch(#"href="([^"]*tid=\d+[^"]*)""#, in: card),
                      let tid = HTML.queryInt("tid", in: href), seen.insert(tid).inserted else { continue }
                let itemTitle = HTML.stripTags(HTML.firstMatch(#"<h2>([\s\S]*?)</h2>"#, in: card) ?? "")
                if itemTitle.isEmpty || SiteConfig.isAdText(itemTitle) { continue }
                let views = HTML.firstMatch(#"class="yd">(\d+)"#, in: card) ?? ""
                let meta = HTML.stripTags(HTML.firstMatch(#"<p>([\s\S]*?)</p>"#, in: card) ?? "")
                let parts = meta.components(separatedBy: "/").map { $0.trimmingCharacters(in: .whitespaces) }
                let author = parts.first ?? ""
                let board = parts.count > 1 ? parts[1] : ""
                let avatar = HTML.firstMatch(#"<img[^>]+src="(/uc_server/[^"]+)"#, in: card)
                let avatarURL: URL? = avatar.flatMap { HTML.absURL($0, base: base) }
                items.append(PortalItem(id: tid, title: itemTitle, author: author, board: board, views: views, avatarURL: avatarURL))
            }
            if !items.isEmpty {
                sections.append(PortalSection(id: "\(index)-\(title)", title: title, moreHref: more, items: items))
            }
        }
        return PortalPage(notices: notices, sections: sections)
    }

    static func parseForumList(_ html: String) -> [ForumCategory] {
        var cats: [ForumCategory] = []
        let tabIDs = HTML.allMatches(#"<li id="a_tab(\d+)""#, in: html, group: 1)
        let tabNames = HTML.allMatches(#"<li id="a_tab\d+"[^>]*>\s*<a href="[^"]*">([^<]+)</a>"#, in: html, group: 1)
        let pairs = Array(zip(tabIDs, tabNames))
        if pairs.isEmpty { return BuiltinForums.categories }

        for (tid, name) in pairs {
            let marker = "id=\"tab\(tid)_content\""
            let block: String
            if let r = html.range(of: marker) {
                block = String(html[r.lowerBound...].prefix(12000))
            } else {
                block = html
            }
            var boards: [ForumBoard] = []
            let hrefs = HTML.allMatches(#"<a href="([^"]*fid=\d+[^"]*)"[^>]*class="btdb"[^>]*>([\s\S]*?)</a>"#, in: block, group: 1)
            let bodies = HTML.allMatches(#"<a href="([^"]*fid=\d+[^"]*)"[^>]*class="btdb"[^>]*>([\s\S]*?)</a>"#, in: block, group: 2)
            for (href, body) in zip(hrefs, bodies) {
                guard let fid = HTML.queryInt("fid", in: href) else { continue }
                if SiteConfig.adFIDs.contains(fid) { continue }
                let title = HTML.stripTags(body)
                    .replacingOccurrences(of: #"^\d+"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if title.isEmpty || SiteConfig.isAdText(title) { continue }
                let num = Int(HTML.firstMatch(#"<span class="num">(\d+)</span>"#, in: body) ?? "0") ?? 0
                let meta = HTML.stripTags(HTML.firstMatch(#"<i>([\s\S]*?)</i>"#, in: block.components(separatedBy: href).dropFirst().first ?? "") ?? "")
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                boards.append(ForumBoard(id: fid, name: title, today: num, meta: meta))
            }
            if !boards.isEmpty {
                cats.append(ForumCategory(id: tid, name: HTML.stripTags(name), boards: boards))
            }
        }
        return cats.isEmpty ? BuiltinForums.categories : cats
    }

    static func parseThreadList(_ html: String, fid: Int, page: Int) -> ThreadListPage {
        let boardName = HTML.stripTags(HTML.firstMatch(#"<title>([^-<]+)"#, in: html) ?? "")
        var types: [ThreadType] = [ThreadType(id: 0, name: "全部")]
        let typeIDs = HTML.allMatches(#"filter=typeid&amp;typeid=(\d+)"#, in: html, group: 1)
        let typeNames = HTML.allMatches(#"filter=typeid&amp;typeid=\d+[^>]*>([^<]+)</a>"#, in: html, group: 1)
        var seenType = Set<Int>()
        for (idS, name) in zip(typeIDs, typeNames) {
            guard let id = Int(idS), seenType.insert(id).inserted else { continue }
            let n = HTML.stripTags(name)
            if n.isEmpty || SiteConfig.isAdText(n) { continue }
            types.append(ThreadType(id: id, name: n))
        }

        var threads: [ThreadItem] = []
        var seenTID = Set<Int>()

        let stickyLis = HTML.allMatches(#"<li>\s*<i>([^<]*)</i>\s*<a href="([^"]*tid=\d+[^"]*)"[^>]*>([\s\S]*?)</a>\s*</li>"#, in: html, group: 2)
        let stickyTitles = HTML.allMatches(#"<li>\s*<i>([^<]*)</i>\s*<a href="([^"]*tid=\d+[^"]*)"[^>]*>([\s\S]*?)</a>\s*</li>"#, in: html, group: 3)
        let stickyDates = HTML.allMatches(#"<li>\s*<i>([^<]*)</i>\s*<a href="([^"]*tid=\d+[^"]*)"[^>]*>([\s\S]*?)</a>\s*</li>"#, in: html, group: 1)
        for (href, titleHTML, date) in zip3(stickyLis, stickyTitles, stickyDates) {
            guard let tid = HTML.queryInt("tid", in: href), seenTID.insert(tid).inserted else { continue }
            let title = HTML.stripTags(titleHTML)
            if title.isEmpty || SiteConfig.isAdText(title) { continue }
            threads.append(ThreadItem(id: tid, title: title, excerpt: "", author: "", authorID: nil, avatarURL: nil, coverURL: nil, dateText: date, replies: "", likes: "", views: "", isSticky: true, fid: fid))
        }

        let cards = html.components(separatedBy: "n5_htmk")
        for raw in cards.dropFirst() {
            let card = "n5_htmk" + raw
            guard let tidS = HTML.firstMatch(#"mod=viewthread&amp;tid=(\d+)"#, in: card)
                    ?? HTML.firstMatch(#"mod=viewthread&tid=(\d+)"#, in: card),
                  let tid = Int(tidS) else { continue }
            if !seenTID.insert(tid).inserted { continue }

            if card.contains("id=\"links\"") || card.contains("class=\"show-text") { continue }
            let title = HTML.stripTags(
                HTML.firstMatch(#"class="n5_htnrbt[^"]*"[^>]*>\s*<a[^>]*>([\s\S]*?)</a>"#, in: card)
                    ?? HTML.firstMatch(#"<h1>\s*<a[^>]*>([\s\S]*?)</a>"#, in: card)
                    ?? ""
            )
            if title.isEmpty { continue }
            if SiteConfig.isAdText(title) { continue }

            let excerpt = HTML.stripTags(HTML.firstMatch(#"<p>\s*<a[^>]*>([\s\S]*?)</a>"#, in: card) ?? "")
            let author = HTML.stripTags(HTML.firstMatch(#"class="n5_mktbhy"[^>]*>\s*<a[^>]*>([\s\S]*?)</a>"#, in: card) ?? "")
            let authorID = Int(HTML.firstMatch(#"uid=(\d+)"#, in: card) ?? "")
            let dateText = HTML.stripTags(HTML.firstMatch(#"class="n5_mktbsj[^"]*"[^>]*>([\s\S]*?)</span>"#, in: card) ?? "")
                .replacingOccurrences(of: "发布", with: "")
                .trimmingCharacters(in: .whitespaces)
            let avatar = HTML.firstMatch(#"<img[^>]+src="(/uc_server/[^"]+)"#, in: card)
            let covers = HTML.allMatches(#"data-original="(https?://[^"]+)"#, in: card, group: 1)
            let cover = covers.first
            let replies = HTML.stripTags(HTML.firstMatch(#"n5_hthfcs[\s\S]{0,180}?</i>\s*([^<]+)"#, in: card) ?? "")
            let likes = HTML.stripTags(HTML.firstMatch(#"n5_htdzcs[\s\S]{0,180}?</i>\s*([^<]+)"#, in: card) ?? "")
            let views = HTML.stripTags(HTML.firstMatch(#"n5_htsccs[\s\S]{0,180}?</i>\s*([^<]+)"#, in: card) ?? "")

            let coverURL = cover.flatMap { URL(string: HTML.unescape($0)) }
            let avatarURL: URL? = avatar.flatMap {
                if $0.hasPrefix("http") { return URL(string: $0) }
                return URL(string: "https://\(SiteConfig.defaultHost)\($0)")
            }

            threads.append(ThreadItem(
                id: tid, title: title, excerpt: excerpt, author: author,
                authorID: authorID, avatarURL: avatarURL, coverURL: coverURL,
                dateText: dateText, replies: replies, likes: likes, views: views,
                isSticky: false, fid: fid
            ))
        }

        let hasNext = html.contains("page=\(page + 1)") || html.contains(">下一页<")
        return ThreadListPage(threads: threads, types: types, page: page, hasNext: hasNext, boardName: boardName)
    }

    static func parseThreadDetail(_ html: String, tid: Int, base: URL) -> ThreadDetail {
        let pageTitle = HTML.stripTags(HTML.firstMatch(#"<title>([\s\S]*?)</title>"#, in: html) ?? "")
        let parts = pageTitle.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }
        let title = HTML.stripTags(
            HTML.firstMatch(#"<span class="dqym">([\s\S]*?)</span>"#, in: html)
                ?? parts.first
                ?? ""
        )
        let boardName = parts.count > 1 ? parts[1] : ""

        var magnets: [ThreadAttachment] = []
        var seenMag = Set<String>()
        for m in HTML.allMatches(#"(magnet:\?xt=[^"'<>\s]+)"#, in: html, group: 1) {
            let u = HTML.unescape(m)
            if seenMag.insert(u).inserted, let url = URL(string: u) {
                magnets.append(ThreadAttachment(id: u, name: "磁力链接", url: url))
            }
        }
        for m in HTML.allMatches(#"(ed2k://\|file\|[^"'<>\s]+)"#, in: html, group: 1) {
            let u = HTML.unescape(m)
            if seenMag.insert(u).inserted, let url = URL(string: u) {
                magnets.append(ThreadAttachment(id: u, name: "eD2k", url: url))
            }
        }

        var attachments: [ThreadAttachment] = []
        let attHrefs = HTML.allMatches(#"<a[^>]+href="([^"]*mod=attachment[^"]*)"[^>]*>([\s\S]*?)</a>"#, in: html, group: 1)
        let attNames = HTML.allMatches(#"<a[^>]+href="([^"]*mod=attachment[^"]*)"[^>]*>([\s\S]*?)</a>"#, in: html, group: 2)
        for (href, name) in zip(attHrefs, attNames) {
            guard let url = HTML.absURL(href, base: base) else { continue }
            let n = HTML.stripTags(name)
            if n.isEmpty { continue }
            attachments.append(ThreadAttachment(id: url.absoluteString, name: n, url: url))
        }

        var images: [URL] = []
        var seenImg = Set<String>()
        for c in HTML.allMatches(#"<img[^>]+(?:zoomfile|file|data-original|src)="(https?://[^"]+)"#, in: html, group: 1) {
            let u = HTML.unescape(c)
            if u.contains("avatar") || u.contains("static/image") || u.contains("noavatar") { continue }
            if u.contains("icon") || u.contains("smiley") { continue }
            if seenImg.insert(u).inserted, let url = URL(string: u) { images.append(url) }
        }

        var posts: [ThreadPost] = []
        let postBlocks = html.components(separatedBy: "id=\"post_")
        if postBlocks.count > 1 {
            for raw in postBlocks.dropFirst() {
                let block = "id=\"post_" + raw
                let pid = HTML.firstMatch(#"id="post_(\d+)"#, in: block) ?? UUID().uuidString
                let author = HTML.stripTags(HTML.firstMatch(#"class="n5_mktbhy"[^>]*>\s*<a[^>]*>([\s\S]*?)</a>"#, in: block) ?? "")
                let dateText = HTML.stripTags(HTML.firstMatch(#"class="n5_mktbsj[^"]*"[^>]*>([\s\S]*?)</span>"#, in: block) ?? "")
                let body = HTML.firstMatch(#"class="[^"]*message[^"]*"[^>]*>([\s\S]*?)</div>"#, in: block) ?? ""
                let plain = HTML.stripTags(body)
                if SiteConfig.isAdText(plain) && plain.count < 80 { continue }
                var pImages: [URL] = []
                for c in HTML.allMatches(#"<img[^>]+(?:zoomfile|file|data-original|src)="(https?://[^"]+)"#, in: body, group: 1) {
                    let u = HTML.unescape(c)
                    if u.contains("avatar") || u.contains("static/image") { continue }
                    if let url = URL(string: u) { pImages.append(url) }
                }
                posts.append(ThreadPost(id: pid, author: author, authorID: nil, avatarURL: nil, dateText: dateText, htmlBody: body, plainText: plain, images: pImages))
            }
        }
        if posts.isEmpty {
            let plain = HTML.stripTags(html)
            posts.append(ThreadPost(id: "op", author: "", authorID: nil, avatarURL: nil, dateText: "", htmlBody: "", plainText: String(plain.prefix(4000)), images: images))
        }

        return ThreadDetail(tid: tid, title: title, boardName: boardName, fid: nil, posts: posts, magnets: magnets, attachments: attachments, images: images)
    }

    static func parseSearch(_ html: String) -> [SearchHit] {
        var hits: [SearchHit] = []
        var seen = Set<Int>()
        let hrefs = HTML.allMatches(#"<a href="([^"]*tid=\d+[^"]*)"[^>]*>([\s\S]*?)</a>"#, in: html, group: 1)
        let titles = HTML.allMatches(#"<a href="([^"]*tid=\d+[^"]*)"[^>]*>([\s\S]*?)</a>"#, in: html, group: 2)
        for (href, t) in zip(hrefs, titles) {
            guard let tid = HTML.queryInt("tid", in: href), seen.insert(tid).inserted else { continue }
            let title = HTML.stripTags(t)
            if title.isEmpty || SiteConfig.isAdText(title) { continue }
            if ["下一页", "上一页", "返回"].contains(title) { continue }
            hits.append(SearchHit(id: tid, title: title, excerpt: "", board: "", author: "", dateText: ""))
        }
        return hits
    }

    static func loggedInUsername(_ html: String) -> String? {
        if html.contains("discuz_uid = '0'") || html.contains("discuz_uid = \"0\"") { return nil }
        if let u = HTML.firstMatch(#"discuz_uid = '(\d+)'"#, in: html), u != "0" {
            return "已登录"
        }
        if html.contains("action=logout") { return "已登录" }
        return nil
    }

    static func looksLikeChallenge(_ html: String) -> Bool {
        let t = html.lowercased()
        return t.contains("just a moment") || t.contains("cf-challenge") || t.contains("checking your browser")
            || (t.contains("满18岁") && t.contains("warning"))
    }
}

private func zip3<A, B, C>(_ a: [A], _ b: [B], _ c: [C]) -> [(A, B, C)] {
    let n = min(a.count, b.count, c.count)
    return (0..<n).map { (a[$0], b[$0], c[$0]) }
}
