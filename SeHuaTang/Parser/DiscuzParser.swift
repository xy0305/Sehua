import Foundation

enum DiscuzParser {
    static func parsePortal(_ html: String, base: URL) -> PortalPage {
        var notices: [SiteNotice] = []
        var seenNotice = Set<Int>()
        if let box = HTML.elements(in: html, className: "n5_ggmk").first {
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

        // Collect excluded IDs from the FULL document before any row/card extraction.
        // Live n5 forumdisplay (fid 95 and 103) uses n5_zdtys > ul > li > i + a
        // for its fixed top notices; those li have no displayorder/pin metadata.
        // This scope is forum lists only: portal notices and ordinary date li remain intact.
        let stickyBlocks = HTML.elements(in: html) { tag in
            isStickyContainer(tag) || HTML.hasClass("n5_zdtys", in: tag)
        }
        let markedRows = HTML.elements(in: html) { tag in
            HTML.hasClass("n5_htmk", in: tag)
                || (HTML.attribute("id", in: tag) ?? "").hasPrefix("normalthread_")
                || HTML.firstMatch(#"^<(li)\b"#, in: tag) != nil
        }.filter { isStickyThread($0) }
        let stickyIDs = Set((stickyBlocks + markedRows).flatMap { block in
            HTML.allMatches(#"(?:tid=|thread-)(\d+)"#, in: HTML.unescape(block)).compactMap(Int.init)
        })
        // Compact mobile notice rows are not sticky merely because they use <li><i>date</i>.
        for row in HTML.elements(in: html, tag: "li") {
            guard !isStickyThread(row),
                  HTML.firstMatch(#"^<li[^>]*>\s*<i>"#, in: row, group: 0) != nil,
                  let href = HTML.firstMatch(#"<a[^>]*href=["']([^"']*tid=\d+[^"']*)["']"#, in: row),
                  let tid = HTML.queryInt("tid", in: href), !stickyIDs.contains(tid),
                  seenTID.insert(tid).inserted else { continue }
            let title = HTML.stripTags(HTML.elements(in: row, tag: "a", inner: true).first ?? "")
            guard !title.isEmpty, !SiteConfig.isAdText(title) else { continue }
            threads.append(ThreadItem(id: tid, title: title, excerpt: "", author: "", authorID: nil,
                avatarURL: nil, coverURL: nil, dateText: "", replies: "", likes: "", views: "", isSticky: false, fid: fid))
        }

        let cards = HTML.elements(in: html, className: "n5_htmk")
        let listBase = URL(string: "https://\(SiteConfig.defaultHost)/")!
        for card in cards {
            guard let tidS = HTML.firstMatch(#"mod=viewthread&amp;tid=(\d+)"#, in: card)
                    ?? HTML.firstMatch(#"mod=viewthread&tid=(\d+)"#, in: card),
                  let tid = Int(tidS) else { continue }
            if stickyIDs.contains(tid) || isStickyThread(card) { continue }
            if !seenTID.insert(tid).inserted { continue }

            if !HTML.elements(in: card, idPrefix: "links").isEmpty { continue }
            let title = HTML.stripTags(
                HTML.elements(in: card, className: "n5_htnrbt", inner: true).first
                    ?? HTML.firstMatch(#"<h1>\s*<a[^>]*>([\s\S]*?)</a>"#, in: card)
                    ?? ""
            )
            if title.isEmpty { continue }
            if SiteConfig.isAdText(title) { continue }

            let excerpt = HTML.stripTags(HTML.elements(in: card, className: "n5_htnrjj", inner: true).first
                ?? HTML.firstMatch(#"<p>\s*<a[^>]*>([\s\S]*?)</a>"#, in: card) ?? "")
            let author = HTML.stripTags(HTML.firstMatch(#"class="n5_mktbhy"[^>]*>\s*<a[^>]*>([\s\S]*?)</a>"#, in: card) ?? "")
            let authorID = Int(HTML.firstMatch(#"uid=(\d+)"#, in: card) ?? "")
            let dateText = HTML.stripTags(HTML.firstMatch(#"class="n5_mktbsj[^"]*"[^>]*>([\s\S]*?)</span>"#, in: card) ?? "")
                .replacingOccurrences(of: "发布", with: "")
                .trimmingCharacters(in: .whitespaces)
            let avatarURL = avatarURL(in: card, base: listBase)
            let previewURLs = Array(HTML.imageURLs(in: card, base: listBase)
                .filter { $0 != avatarURL }
                .prefix(3))
            let coverURL = previewURLs.first
            let replies = statistic("n5_hthfcs", in: card)
            let likes = statistic("n5_htdzcs", in: card)
            let views = statistic("n5_htsccs", in: card)

            threads.append(ThreadItem(
                id: tid, title: title, excerpt: excerpt, author: author,
                authorID: authorID, avatarURL: avatarURL, coverURL: coverURL,
                dateText: dateText, replies: replies, likes: likes, views: views,
                isSticky: false, fid: fid, previewURLs: previewURLs
            ))
        }

        // Standard PC Discuz rows; normal announcements stay visible unless sticky metadata says otherwise.
        for row in HTML.elements(in: html, idPrefix: "normalthread_") {
            guard !isStickyThread(row),
                  let tid = HTML.firstMatch(#"normalthread_(\d+)"#, in: row).flatMap(Int.init),
                  !stickyIDs.contains(tid), seenTID.insert(tid).inserted else { continue }
            let subject = HTML.elements(in: row, className: "s xst", inner: true).first
                ?? HTML.elements(in: row, tag: "a").first(where: { HTML.hasClass("xst", in: $0) })
                ?? ""
            let title = HTML.stripTags(subject)
            guard !title.isEmpty, !SiteConfig.isAdText(title) else { continue }
            threads.append(ThreadItem(id: tid, title: title, excerpt: "", author: "", authorID: nil,
                avatarURL: nil, coverURL: nil, dateText: "", replies: "", likes: "", views: "", isSticky: false, fid: fid))
        }

        let pagination = threadPagination(html, fid: fid, page: page)
        return ThreadListPage(threads: threads, types: types, page: page,
                              hasNext: pagination.hasNext, boardName: boardName,
                              totalPages: pagination.total)
    }

    private static func isStickyContainer(_ tag: String) -> Bool {
        let id = (HTML.attribute("id", in: tag) ?? "").lowercased()
        if id.hasPrefix("stickthread_") || HTML.hasClass("stickthread", in: tag) { return true }
        for key in ["displayorder", "data-displayorder", "data-sticky"] {
            if let value = HTML.attribute(key, in: tag).flatMap(Int.init), value > 0 { return true }
        }
        return false
    }

    private static func isStickyThread(_ block: String) -> Bool {
        // Inspect attributes/icons only. A normal title containing “置顶” is not metadata.
        for tag in HTML.allMatches(#"(<[A-Za-z][^>]*>)"#, in: block) {
            if isStickyContainer(tag) { return true }
            if let src = HTML.attribute("src", in: tag),
               HTML.firstMatch(#"(?:^|/)pin_[123]\.(?:gif|png)(?:\?|$)"#, in: src, group: 0) != nil { return true }
            if HTML.firstMatch(#"^<img\b"#, in: tag, group: 0) != nil,
               ["置顶", "全局置顶", "分区置顶", "版块置顶"].contains(HTML.attribute("alt", in: tag) ?? "") { return true }
        }
        return false
    }

    // Only pagination containers are authoritative; thread/reply links are not totals.
    private static func threadPagination(_ html: String, fid: Int, page: Int) -> (total: Int?, hasNext: Bool) {
        let boxes = ["pg", "page", "pgs", "n5_fy", "n5_page"].flatMap { HTML.elements(in: html, className: $0) }
        var totals: [Int] = []
        var next = false
        for box in boxes {
            let decoded = HTML.unescape(box)
            if let text = HTML.firstMatch(#"(?:共\s*|/\s*)(\d+)\s*页"#, in: decoded), let n = Int(text), n > 0 { totals.append(n) }
            var numbers = Set<Int>()
            var truncated = decoded.contains("...") || decoded.contains("…")
            for anchor in HTML.allMatches(#"(<a\b[^>]*>[\s\S]*?</a>)"#, in: decoded) {
                guard let href = HTML.firstMatch(#"href\s*=\s*["']([^"']+)["']"#, in: anchor),
                      HTML.queryInt("fid", in: href) == fid,
                      let n = HTML.queryInt("page", in: href), n > 0 else { continue }
                let label = HTML.stripTags(anchor).trimmingCharacters(in: .whitespacesAndNewlines)
                if n > page { next = true }
                let last = HTML.firstMatch(#"class\s*=\s*["'][^"']*\blast\b"#, in: anchor, group: 0) != nil || label.contains("末页") || label.contains("最后")
                if last { totals.append(n) }
                if let numeric = Int(label), numeric == n { numbers.insert(n) }
                if label.contains("...") || label.contains("…") { truncated = true }
            }
            for current in HTML.allMatches(#"<(?:strong|span)[^>]*>\s*(\d+)\s*</(?:strong|span)>"#, in: decoded) {
                if let n = Int(current), n > 0 { numbers.insert(n) }
            }
            // A complete 1...N numeric bar (without an omitted window) gives a real total.
            if !truncated, !decoded.contains("下一页"),
               HTML.firstMatch(#"class\s*=\s*["'][^"']*\bnxt\b"#, in: decoded, group: 0) == nil,
               let maximum = numbers.max(), numbers.min() == 1,
               numbers.count == maximum,
               !HTML.allMatches(#"href\s*=\s*["']([^"']+)["']"#, in: decoded).contains(where: {
                   HTML.queryInt("fid", in: $0) == fid && (HTML.queryInt("page", in: $0) ?? 0) > maximum
               }) { totals.append(maximum) }
        }
        let total = totals.max()
        if let total { return (total, page < total) }
        // Older mobile skins expose a next link without a recognised wrapper.
        if boxes.isEmpty {
            for anchor in HTML.allMatches(#"(<a\b[^>]*>[\s\S]*?</a>)"#, in: HTML.unescape(html)) {
                guard let href = HTML.firstMatch(#"href\s*=\s*["']([^"']+)["']"#, in: anchor),
                      HTML.queryInt("fid", in: href) == fid,
                      HTML.queryInt("page", in: href) == page + 1 else { continue }
                next = true
            }
        }
        return (nil, next)
    }

    static func parseThreadDetail(_ html: String, tid: Int, base: URL, fallbackTitle: String = "") -> ThreadDetail {
        let pageTitle = HTML.stripTags(HTML.firstMatch(#"<title>([\s\S]*?)</title>"#, in: html) ?? "")
        let parts = pageTitle.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }
        // dqym and generic h1 are navigation/board labels, never thread subjects.
        let subject = HTML.stripTags(
            HTML.firstMatch(#"<[^>]+id=["']thread_subject["'][^>]*>([\s\S]*?)</[^>]+>"#, in: html)
                ?? HTML.firstMatch(#"<h[12][^>]+class=["'][^"']*(?:thread_subject|post-title|thread-title)[^"']*["'][^>]*>([\s\S]*?)</h[12]>"#, in: html)
                ?? ""
        )
        let fallback = fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = !subject.isEmpty ? subject : (!fallback.isEmpty ? fallback : (parts.count >= 3 ? parts[0] : ""))
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

        var posts: [ThreadPost] = []
        var seenPosts = Set<String>()
        let postBlocks = HTML.elements(in: html) {
            HTML.firstMatch(#"^(?:post_|pid)\d+$"#, in: HTML.attribute("id", in: $0) ?? "", group: 0) != nil
        }
        for (index, block) in postBlocks.enumerated() {
            let pid = HTML.firstMatch(#"^(?:post_|pid)(\d+)$"#, in: HTML.attribute("id", in: block) ?? "") ?? "post-\(index)"
            let header = HTML.elements(in: block, className: "n5_mktb").first ?? block
            let authorBlock = HTML.elements(in: header, className: "n5_mktbhy", inner: true).first
                ?? HTML.elements(in: header, className: "n5_yhmhdj", inner: true).first
                ?? HTML.elements(in: header, className: "authi", inner: true).first ?? ""
            let author = HTML.stripTags(HTML.elements(in: authorBlock, tag: "a", inner: true).first ?? authorBlock)
            let authorID = HTML.firstMatch(#"(?:uid=|space-uid-)(\d+)"#, in: authorBlock).flatMap(Int.init)
            let dateText = HTML.stripTags(HTML.elements(in: header, className: "n5_mktbsj", inner: true).first
                ?? HTML.elements(in: header, className: "n5_sjydhf", inner: true).first.flatMap { HTML.elements(in: $0, tag: "dt", inner: true).first }
                ?? HTML.elements(in: header, idPrefix: "authorposton", inner: true).first ?? "")
            let bodyFallback = messageBodies(in: block).map(cleanRatingComponents).joined(separator: "\n")
            guard !bodyFallback.isEmpty, seenPosts.insert(pid).inserted else { continue }
            let plain = HTML.plainText(bodyFallback)
            if SiteConfig.isAdText(plain) && plain.count < 80 { continue }
            posts.append(ThreadPost(id: pid, author: author, authorID: authorID,
                avatarURL: avatarURL(in: header, base: base), dateText: dateText,
                htmlBody: bodyFallback, plainText: HTML.plainText(bodyFallback), images: HTML.imageURLs(in: bodyFallback, base: base), ratings: parseRatings(in: block, base: base)))
        }
        // Some mobile skins omit post_<pid>; still extract only the actual message,
        // never turn navigation, advertisements and footer text into a synthetic post.
        if posts.isEmpty {
            for (index, rawBody) in messageBodies(in: html).enumerated() {
                let body = cleanRatingComponents(rawBody)
                posts.append(ThreadPost(id: "unwrapped-\(HTML.queryInt("page", in: base.absoluteString) ?? HTML.firstMatch(#"thread-\d+-(\d+)-\d+\.html"#, in: base.absoluteString).flatMap(Int.init) ?? 1)-\(index)", author: "", authorID: nil, avatarURL: nil,
                    dateText: "", htmlBody: body, plainText: HTML.plainText(body), images: HTML.imageURLs(in: body, base: base), ratings: parseRatings(in: rawBody, base: base)))
            }
        }
        var seenImages = Set<String>()
        let images = posts.flatMap { $0.images }.filter { seenImages.insert($0.absoluteString).inserted }
        let links = HTML.elements(in: html, tag: "a").compactMap { HTML.attribute("href", in: $0) }
        let favorite = links.first { href in
            guard let components = URLComponents(string: href) else { return false }
            let query = components.queryItems ?? []
            return query.contains { $0.name == "ac" && $0.value == "favorite" }
                && query.contains { $0.name == "type" && $0.value == "thread" }
                && HTML.queryInt("id", in: href) == tid
        }
        let replyLinks = links.filter { href in
            guard let components = URLComponents(string: href) else { return false }
            return (components.queryItems ?? []).contains { $0.name == "action" && $0.value == "reply" }
                && HTML.queryInt("tid", in: href) == tid
        }
        let reply = replyLinks.first { HTML.queryInt("repquote", in: $0) == nil } ?? replyLinks.first
        // Global board navigation and links inside post bodies are not provenance.
        // Use a reply action for this exact tid, or the thread's breadcrumb only.
        let breadcrumb = HTML.elements(in: html).first {
            HTML.attribute("id", in: $0) == "pt" || HTML.attribute("class", in: $0)?.split(separator: " ").contains("breadcrumb") == true
        } ?? ""
        let boardLinks = HTML.elements(in: breadcrumb, tag: "a").compactMap { HTML.attribute("href", in: $0) }
        let fid = reply.flatMap { HTML.queryInt("fid", in: $0) }
            ?? boardLinks.last(where: { $0.contains("mod=forumdisplay") || $0.contains("forum-") }).flatMap {
                HTML.queryInt("fid", in: $0) ?? HTML.firstMatch(#"forum-(\d+)-"#, in: $0).flatMap(Int.init)
            }
        let replyCount = HTML.firstMatch(#"网友回复（(\d+)条）"#, in: html) ?? ""

        return ThreadDetail(tid: tid, title: title, boardName: boardName, fid: fid, replyCount: replyCount, favoriteURL: favorite.flatMap { HTML.absURL($0, base: base) }, replyURL: reply.flatMap { HTML.absURL($0, base: base) }, posts: posts, magnets: magnets, attachments: attachments, images: images)
    }

    // Select component identity, not generic tables/images or the word 评分 in body text.
    static func isRatingComponent(_ tag: String) -> Bool {
        let id = (HTML.attribute("id", in: tag) ?? "").lowercased()
        return id.hasPrefix("ratelog") || id.hasPrefix("ratewater")
            || ["ratl", "ratelog", "ratewater", "rating-list"].contains { HTML.hasClass($0, in: tag) }
    }

    static func ratingComponents(in html: String) -> [String] {
        HTML.elements(in: html, matching: isRatingComponent)
    }

    static func cleanRatingComponents(_ html: String) -> String {
        var result = html
        for component in ratingComponents(in: html) {
            result = result.replacingOccurrences(of: component, with: "")
        }
        return result
    }

    static func parseRatings(in html: String, base: URL) -> PostRatings? {
        let components = ratingComponents(in: html)
        guard !components.isEmpty else { return nil }
        let scope = components.joined(separator: "\n")
        var participants: String?
        var totals: [String] = []
        var entries: [RatingEntry] = []
        for row in HTML.elements(in: scope, tag: "tr") {
            let cells = HTML.elements(in: row) { tag in
                HTML.firstMatch(#"^<(?:td|th)\b"#, in: tag, group: 0) != nil
            }
            let texts = cells.map(HTML.stripTags)
            let rowText = HTML.stripTags(row)
            if rowText.contains("参与人数") {
                participants = HTML.firstMatch(#"参与人数\s*(\d+)"#, in: rowText)
                totals = texts.compactMap { text in
                    guard !text.contains("参与人数"), !text.contains("理由"), !text.contains("收起"), !text.contains("展开"),
                          HTML.firstMatch(#"[+−-]\s*\d+"#, in: text, group: 0) != nil else { return nil }
                    return text
                }
                continue
            }
            guard let first = cells.first else { continue }
            let members = HTML.elements(in: first, tag: "a").filter { anchor in
                HTML.firstMatch(#"(?:uid=|space-uid-)(\d+)"#, in: HTML.unescape(anchor)) != nil
            }
            let member = members.first { !HTML.stripTags($0).isEmpty } ?? members.first
            // Never fabricate users from a malformed summary/header row.
            guard let member else { continue }
            let uid = HTML.firstMatch(#"(?:uid=|space-uid-)(\d+)"#, in: HTML.unescape(member)).flatMap(Int.init)
            let name = HTML.stripTags(member)
            let reason = cells.count >= 3 ? HTML.plainText(cells.last ?? "") : ""
            let values = cells.count >= 3 ? Array(texts.dropFirst().dropLast()).filter { !$0.isEmpty } : []
            entries.append(RatingEntry(id: entries.count, name: name, uid: uid,
                avatarURL: HTML.imageURLs(in: first, base: base, excludingDecorations: false).first, values: values, reason: reason))
        }
        return PostRatings(participants: participants, totals: totals, entries: entries)
    }

    static func parseMemberSpace(_ html: String, uid: Int, base: URL) -> MemberSpace {
        let name = HTML.stripTags(HTML.firstMatch(#"<h2[^>]*>([\s\S]*?)</h2>"#, in: html) ?? "")
        var threads: [ThreadItem] = []
        var seen = Set<Int>()
        let pattern = #"<a[^>]+href="([^"]*tid=\d+[^"]*)"[^>]*>([\s\S]*?)</a>"#
        let hrefs = HTML.allMatches(pattern, in: html, group: 1)
        let titles = HTML.allMatches(pattern, in: html, group: 2)
        for pair in zip(hrefs, titles) {
            guard let tid = HTML.queryInt("tid", in: pair.0), seen.insert(tid).inserted else { continue }
            let title = HTML.stripTags(pair.1)
            if title.isEmpty || SiteConfig.isAdText(title) || title == "更多" { continue }
            threads.append(ThreadItem(
                id: tid, title: title, excerpt: "", author: name, authorID: uid,
                avatarURL: nil, coverURL: nil, dateText: "", replies: "", likes: "",
                views: "", isSticky: false, fid: HTML.queryInt("fid", in: pair.0)
            ))
        }
        let paging = memberSpacePage(html, uid: uid, current: HTML.queryInt("page", in: base.absoluteString) ?? 1)
        return MemberSpace(uid: uid, name: name, avatarURL: avatarURL(in: html, base: base), threads: threads, page: paging.page, totalPages: paging.total, hasNext: paging.hasNext)
    }

    static func memberSpacePage(_ html: String, uid: Int, current: Int) -> (page: Int, total: Int?, hasNext: Bool, nextURL: URL?) {
        let boxes = ["pg", "page", "pgs", "n5_fy", "n5_page"].flatMap { HTML.elements(in: html, className: $0) }
        let scope = boxes.isEmpty ? html : boxes.joined(separator: "\n")
        let decoded = HTML.unescape(scope)
        var total = HTML.firstMatch(#"(?:共\s*|/\s*)(\d+)\s*页"#, in: decoded).flatMap(Int.init)
        var page = current
        var hasNext = false
        var nextURL: URL?
        for anchor in HTML.allMatches(#"(<a\b[^>]*>[\s\S]*?</a>)"#, in: decoded) {
            guard let href = HTML.firstMatch(#"href\s*=\s*["']([^"']+)["']"#, in: anchor) else { continue }
            let belongs = HTML.queryInt("uid", in: href) == uid || href.contains("space-uid-\(uid)")
            guard belongs, let n = HTML.queryInt("page", in: href), n > 0 else { continue }
            let label = HTML.stripTags(anchor)
            if label.contains("末页") || label.contains("最后") { total = max(total ?? 0, n) }
            if n == current + 1 || label.contains("下一页") {
                hasNext = true
                if n == current + 1, let url = URL(string: HTML.unescape(href), relativeTo: URL(string: "https://www.sehuatang.org")!) {
                    nextURL = url
                }
            }
            if label == "\(n)", n == current { page = n }
        }
        if let total, page >= total { hasNext = false }
        return (page, total, hasNext, nextURL)
    }

    static func messageBodies(in html: String) -> [String] {
        HTML.elements(in: html, inner: true) {
            HTML.hasClass("message", in: $0)
                || (HTML.attribute("id", in: $0) ?? "").hasPrefix("postmessage_")
        }
    }

    /// Only forward links for this thread and host. Do not mistake quote/reply,
    /// related-thread or list pagination for detail pagination.
    static func nextThreadPage(in html: String, tid: Int, base: URL, page: Int) -> URL? {
        let candidates = HTML.elements(in: html, tag: "a").compactMap { anchor -> (Int, URL)? in
            guard let href = HTML.attribute("href", in: anchor), let url = HTML.absURL(href, base: base),
                  url.host == base.host, ["https", "http"].contains(url.scheme ?? ""),
                  HTML.queryInt("tid", in: href) == tid else { return nil }
            let decoded = HTML.unescape(href)
            let seoPage = HTML.firstMatch(#"thread-\d+-(\d+)-\d+\.html"#, in: decoded).flatMap(Int.init)
            guard let p = HTML.queryInt("page", in: decoded) ?? seoPage, p == page + 1 else { return nil }
            if seoPage == nil {
                let items = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems ?? []
                guard items.contains(where: { $0.name == "mod" && $0.value == "viewthread" }),
                      !items.contains(where: { ["action", "pid", "authorid", "ordertype", "view", "goto"].contains($0.name) }) else { return nil }
            }
            return (p, url)
        }
        return candidates.min { $0.0 < $1.0 }?.1
    }

    private static func statistic(_ className: String, in html: String) -> String {
        guard let body = HTML.elements(in: html, className: className, inner: true).first else { return "" }
        return HTML.stripTags(HTML.elements(in: body, tag: "a", inner: true).first ?? body)
    }

    private static func avatarURL(in html: String, base: URL) -> URL? {
        for tag in HTML.elements(in: html, tag: "img") {
            guard let source = HTML.attribute("src", in: tag) ?? HTML.attribute("data-original", in: tag) else { continue }
            if source.lowercased().contains("avatar") || source.contains("uc_server") {
                return HTML.absURL(source, base: base)
            }
        }
        return nil
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

#if PARSER_REGRESSION_TESTS
// macOS: xcrun swiftc -D PARSER_REGRESSION_TESTS SeHuaTang/Parser/*.swift \
//   SeHuaTang/Models/Models.swift SeHuaTang/Config/SiteConfig.swift -o /tmp/parser-tests
// Then run /tmp/parser-tests. Tests compile the actual production implementations.
@main
private enum ParserRegressionTests {
    static func main() {
        let base = URL(string: "https://www.sehuatang.org/forum.php?mod=viewthread&tid=42")!
        precondition(HTML.firstMatch("abc", in: "abc") == nil)
        precondition(HTML.firstMatch("abc", in: "abc", group: 0) == "abc")
        precondition(HTML.unescape("&#65;&#x1F600;") == "A😀")
        let portal = DiscuzParser.parsePortal(#"<div class="n5_ggmk"><ul><li><i>10-01</i><a href="forum.php?mod=viewthread&amp;tid=42">公告</a></li></ul></div>"#, base: base)
        precondition(portal.notices.count == 1 && portal.notices[0].id == 42)
        let listHTML = #"""
        <title>测试版块 - 论坛</title>
        <div class="n5_htmk"><h1 class="n5_htnrbt"><a href="forum.php?mod=viewthread&amp;tid=42">正常帖子</a></h1>
        <div class="show-text">合法摘要</div><span class="n5_hthfcs"><a>123</a></span>
        <span class="n5_htdzcs"><a>45</a></span><span class="n5_htsccs"><a>6,789</a></span>
        <img src="/uc_server/avatar.php?uid=7"><img src="/static/image/icon.png">
        <div><img src="/static/image/loading.gif" data-original="//img.example/cover.jpg"></div>
        <div><img src="https://img.example/cover.jpg"><img file="/images/second.jpg" src="/static/image/loading.gif"></div>
        <div><img data-src="//img.example/third.jpg"><img zoomfile="/images/fourth.jpg"></div></div>
        <div class="n5_htmk"><h1><a href="forum.php?mod=viewthread&amp;tid=43">第二个帖子</a></h1></div>
        """#
        let numericPages = #"<div class='pg'><strong>1</strong><a href='forum.php?mod=forumdisplay&amp;fid=103&amp;page=2'>2</a><a href='forum.php?mod=forumdisplay&amp;fid=103&amp;page=3'>3</a></div>"#
        let numeric = DiscuzParser.parseThreadList(numericPages, fid: 103, page: 1)
        precondition(numeric.totalPages == 3 && numeric.hasNext)
        let lastPages = #"<div class='pg'><strong>1</strong><a class='last' href='forum.php?mod=forumdisplay&amp;fid=103&amp;page=123'>... 123</a></div>"#
        precondition(DiscuzParser.parseThreadList(lastPages, fid: 103, page: 1).totalPages == 123)
        precondition(!DiscuzParser.parseThreadList(lastPages, fid: 103, page: 123).hasNext)
        let unknownPages = #"<div class='page'><a href='forum.php?mod=forumdisplay&amp;fid=103&amp;page=8'>下一页</a></div><a href='forum.php?mod=viewthread&amp;tid=9&amp;page=999'>回复</a>"#
        let unknown = DiscuzParser.parseThreadList(unknownPages, fid: 103, page: 7)
        precondition(unknown.totalPages == nil && unknown.hasNext)
        let windowPages = #"<div class='pg'><strong>1</strong><a href='forum.php?fid=103&amp;page=2'>2</a><a href='forum.php?fid=103&amp;page=3'>下一页</a></div>"#
        precondition(DiscuzParser.parseThreadList(windowPages, fid: 103, page: 1).totalPages == nil)
        precondition(DiscuzParser.parseThreadList("<div>没有分页</div>", fid: 103, page: 1).totalPages == nil)
        let stickyFixtures = #"""
        <div id='stickthread_11'><div class='n5_htmk'><h1><a href='forum.php?mod=viewthread&amp;tid=11'>全局</a></h1></div></div>
        <div class='n5_htmk' data-displayorder='1'><h1><a href='forum.php?mod=viewthread&amp;tid=12'>本版</a></h1></div>
        <div class='n5_htmk'><img src='static/image/common/pin_2.gif'><h1><a href='forum.php?mod=viewthread&amp;tid=13'>分区</a></h1></div>
        <div class='n5_htmk' data-displayorder='0' typeid='3'><h1><a href='forum.php?mod=viewthread&amp;tid=14'>普通标题含置顶</a></h1></div>
        <tbody id='stickthread_15'><tr><th><a class='s xst' href='forum.php?mod=viewthread&amp;tid=15'>PC全局</a></th></tr></tbody>
        <tbody id='normalthread_16' displayorder='1'><tr><th><a class='s xst' href='forum.php?mod=viewthread&amp;tid=16'>PC本版</a></th></tr></tbody>
        <tbody id='normalthread_17'><tr><th><img src='pin_3.gif'><a class='s xst' href='forum.php?mod=viewthread&amp;tid=17'>PC分区</a></th></tr></tbody>
        <tbody id='normalthread_18' typeid='99'><tr><th><a class='s xst' href='forum.php?mod=viewthread&amp;tid=18'>非置顶公告</a></th></tr></tbody>
        <li><i>10-01</i><a href='forum.php?mod=viewthread&amp;tid=19'>普通公告</a></li>
        """#
        let filtered = DiscuzParser.parseThreadList(stickyFixtures + numericPages, fid: 103, page: 1)
        precondition(Set(filtered.threads.map(\.id)) == Set([14, 18, 19]))
        precondition(filtered.totalPages == 3 && filtered.hasNext)
        let emptySticky = #"<div class='n5_htmk' displayorder='3'><h1><a href='forum.php?mod=viewthread&amp;tid=77'>全置顶</a></h1></div>"#
        let emptyPage = DiscuzParser.parseThreadList(emptySticky + unknownPages, fid: 103, page: 7)
        precondition(emptyPage.threads.isEmpty && emptyPage.hasNext && emptyPage.totalPages == nil)
        let endPage = DiscuzParser.parseThreadList(emptySticky + numericPages, fid: 103, page: 3)
        precondition(endPage.threads.isEmpty && !endPage.hasNext && endPage.totalPages == 3)
        // Structural fixture reconstructed from live DOM on 2026-10-03, not authenticated HTML.
        // n5_zdtys contains an orderby sibling and bare dated li; no sticky attrs/icons.
        let n5TopNotices = #"""
        <div class='bg'><div class='n5_zdtys'><div class='orderby'><a href='forum.php?fid=95'>排序</a></div>
        <ul><li><i>2026-08-01</i><a href='forum.php?mod=viewthread&amp;tid=201'>公告甲</a></li>
        <li><i>2026-03-11</i><a href='forum.php?mod=viewthread&amp;tid=202'>公告乙</a></li></ul></div>
        <div class='n5_htmk'><h1><a href='forum.php?mod=viewthread&amp;tid=201'>重复移动卡片</a></h1></div>
        <tbody id='normalthread_202'><tr><th><a class='s xst' href='forum.php?tid=202'>重复PC行</a></th></tr></tbody>
        <li><i>2026-10-03</i><a href='forum.php?tid=203'>普通日期公告</a></li>
        <div data-displayorder='2'><section><div class='n5_htmk'><h1><a href='forum.php?mod=viewthread&amp;tid=204'>父级置顶</a></h1></div></section></div>
        <li><i>2026-10-03</i><a href='forum.php?tid=205'>先出现的fallback</a></li>
        <div class='n5_htmk'><img src='pin_1.gif'><h1><a href='forum.php?mod=viewthread&amp;tid=205'>后出现的置顶卡片</a></h1></div>
        <div class='n5_htmk' data-displayorder='0'><h1><a href='forum.php?mod=viewthread&amp;tid=206'>永久访问 置顶 公告</a></h1><span class='n5_hthfcs'>0</span></div>
        </div>
        """#
        for testFID in [95, 103, 97] {
            let result = DiscuzParser.parseThreadList(n5TopNotices + numericPages, fid: testFID, page: 1)
            precondition(Set(result.threads.map(\.id)) == Set([203, 206]))
        }
        let onlyNotices = #"<div class='n5_zdtys'><ul><li><i>10-01</i><a href='forum.php?tid=207'>公告</a></li></ul></div>"#
        let noticesPage = DiscuzParser.parseThreadList(onlyNotices + unknownPages, fid: 103, page: 7)
        precondition(noticesPage.threads.isEmpty && noticesPage.hasNext && noticesPage.totalPages == nil)
        let compatibility = ThreadListPage(threads: [], types: [], page: 1, hasNext: false, boardName: "")
        precondition(compatibility.totalPages == nil)
        let list = DiscuzParser.parseThreadList(listHTML, fid: 103, page: 1)
        precondition(list.threads.count == 2)
        precondition(list.threads[0].replies == "123" && list.threads[0].likes == "45" && list.threads[0].views == "6,789")
        precondition(list.threads[0].coverURL?.absoluteString == "https://img.example/cover.jpg")
        precondition(list.threads[0].previewURLs.map { $0.absoluteString } == [
            "https://img.example/cover.jpg",
            "https://\(SiteConfig.defaultHost)/images/second.jpg",
            "https://img.example/third.jpg"
        ])
        precondition(list.threads[0].coverURL == list.threads[0].previewURLs.first)
        precondition(list.threads[1].previewURLs.isEmpty && list.threads[1].coverURL == nil)
        let oneImage = DiscuzParser.parseThreadList(#"<div class='n5_htmk'><h1><a href='forum.php?mod=viewthread&amp;tid=44'>单图帖子</a></h1><img src='//img.example/only.jpg'><img src='//img.example/only.jpg'></div>"#, fid: 103, page: 1)
        precondition(oneImage.threads.count == 1 && oneImage.threads[0].previewURLs.count == 1)
        let detailHTML = #"""
        <title>测试帖子 - 测试版块 - 论坛</title>
        <a href="home.php?type=thread&amp;id=42&amp;mod=spacecp&amp;ac=favorite">收藏</a>
        <a href='forum.php?tid=42&amp;fid=103&amp;action=reply&amp;mod=post'>回复</a>
        <div id='post_100'><div class="n5_mktb">
        <span class="n5_mktbhy"><a href="home.php?mod=space&amp;uid=7">作者甲</a></span>
        <span class="n5_mktbsj">2026-10-01</span><img src='/uc_server/avatar.php?uid=7'></div>
        <div class='extra message' data-note='a > b'><p>第一段</p><div>嵌套内容</div>
        <!-- </div> --><script>var ignored = '</div>';</script><p>最后一段<br>第二行</p>
        <img zoomfile='/images/full.jpg' src='/static/image/loading.gif' file='/images/thumb.jpg'>
        <img src='//img.example/second.jpg'><img src='/images/full.jpg'></div></div>
        <div id="post_101"><span class="n5_mktbhy"><a href="space-uid-8.html">作者乙</a></span>
        <div class="message"><p>回复内容</p></div></div>
        <img src="https://ads.example/banner.jpg">
        """#
        let detail = DiscuzParser.parseThreadDetail(detailHTML, tid: 42, base: base)
        precondition(detail.fid == 103 && detail.favoriteURL != nil && detail.replyURL != nil)
        precondition(!SiteConfig.allowsPurchase(fid: detail.fid))
        let sale = DiscuzParser.parseThreadDetail(detailHTML.replacingOccurrences(of: "fid=103", with: "fid=97"), tid: 42, base: base)
        precondition(sale.fid == 97 && SiteConfig.allowsPurchase(fid: sale.fid))
        let forged = #"<title>资源出售区 购买 - 论坛</title><a href='forum.php?mod=forumdisplay&amp;fid=97'>资源出售区</a><div class='message'>普通正文 <a href='forum.php?mod=forumdisplay&amp;fid=97'>购买</a></div>"#
        precondition(DiscuzParser.parseThreadDetail(forged, tid: 42, base: base).fid == nil)
        precondition(!SiteConfig.allowsPurchase(fid: nil) && !SiteConfig.allowsPurchase(fid: 95))
        let breadcrumb = #"<div id='pt'><a href='forum-97-1.html'>版块</a></div>"#
        precondition(DiscuzParser.parseThreadDetail(breadcrumb, tid: 42, base: base).fid == 97)
        let otherReply = #"<a href='forum.php?mod=post&amp;action=reply&amp;tid=999&amp;fid=97'>回复其他帖</a>"#
        precondition(DiscuzParser.parseThreadDetail(otherReply, tid: 42, base: base).fid == nil)
        let saleList = DiscuzParser.parseThreadList(#"<div class='n5_htmk'><h1><a href='forum.php?mod=viewthread&amp;tid=44'>普通标题</a></h1></div>"#, fid: 97, page: 1)
        precondition(saleList.threads.first?.fid == 97)
        print("PASS: sale provenance, normal/unknown/forged purchase gating")
        precondition(detail.posts.count == 2 && detail.posts[0].authorID == 7 && detail.posts[1].authorID == 8)
        precondition(detail.posts[0].author == "作者甲" && detail.posts[0].dateText == "2026-10-01")
        precondition(detail.posts[0].avatarURL?.path == "/uc_server/avatar.php")
        precondition(detail.posts[0].plainText.contains("最后一段\n第二行"))
        precondition(detail.posts[0].htmlBody.contains("/images/full.jpg") && !detail.posts[0].htmlBody.contains("回复内容"))
        precondition(detail.images.map { $0.absoluteString } == ["https://www.sehuatang.org/images/full.jpg", "https://img.example/second.jpg"])
        precondition(DiscuzParser.parseThreadDetail("<div>导航</div>", tid: 42, base: base).posts.isEmpty)
        let mobileHTML = #"""
        <div id="pid200"><ul class="authi"><div class="n5_yhmhdj"><h3><a href="home.php?uid=9">移动作者</a></h3></div>
        <div class="n5_sjydhf"><dt>8&nbsp;小时前</dt></div><img src="/uc_server/avatar.php?uid=9"></ul>
        <div class="message">正文<div class="blockcode"><div><ol><li>magnet:?xt=urn:btih:ABC</li></ol></div></div>尾段</div>
        <div id="post_rate_200"></div></div>
        <div id="pid201"><ul class="authi"><div class="n5_yhmhdj"><h3><a href="home.php?uid=10">回复作者</a></h3></div></ul><div class="message">回复</div></div>
        """#
        let mobile = DiscuzParser.parseThreadDetail(mobileHTML, tid: 42, base: base)
        precondition(mobile.posts.map { $0.id } == ["200", "201"])
        precondition(mobile.posts[0].author == "移动作者" && mobile.posts[0].authorID == 9)
        precondition(mobile.posts[0].dateText == "8 小时前" && mobile.posts[0].plainText.hasSuffix("尾段"))
        print("PASS: production parser regression fixtures")
        let spaceHTML = #"""
        <h2 class="mt">楼主甲</h2><img src="/uc_server/avatar.php?uid=7">
        <a href="forum.php?mod=viewthread&tid=88&mobile=2">主题一</a>
        <a href="forum.php?mod=viewthread&tid=89">主题二</a>
        """#
        let space = DiscuzParser.parseMemberSpace(spaceHTML, uid: 7, base: base)
        precondition(space.name == "楼主甲" && space.threads.map(\.id) == [88, 89])
        precondition(space.threads[0].authorID == 7 && space.avatarURL?.path == "/uc_server/avatar.php")
        let paged = #"""
        <div class="pg"><strong>1</strong><a href="home.php?mod=space&amp;uid=7&amp;page=2">2</a><a href="home.php?mod=space&amp;uid=7&amp;page=3">下一页</a><span>共 3 页</span></div>
        """#
        let paging = DiscuzParser.memberSpacePage(paged, uid: 7, current: 1)
        precondition(paging.total == 3 && paging.hasNext && paging.page == 1)
    }
}
#endif
