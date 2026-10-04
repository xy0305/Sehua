import Foundation

/// Standalone macOS CI executable; no app/UI test target or live network.
@main struct ResourceLinkExtractorFixtures {
    static let base = URL(string: "https://forum.invalid/thread-1.html")!
    static let a = "magnet:?xt=urn:btih:" + String(repeating: "a", count: 40)
    static let b = "magnet:?xt=urn:btih:" + String(repeating: "b", count: 40)
    static let ed = "ed2k://|file|movie%20one.mkv|42|" + String(repeating: "c", count: 32) + "|h=ABC|/"
    static func attachment(_ name: String, _ path: String) -> ThreadAttachment {
        let url = URL(string: path, relativeTo: base)!.absoluteURL
        return ThreadAttachment(id: path, name: name, url: url)
    }
    static func detail(_ body: String, _ items: [ThreadAttachment] = []) -> ThreadDetail {
        let post = ThreadPost(id: "p1", author: "", dateText: "", htmlBody: body, plainText: "", images: [])
        return ThreadDetail(tid: 1, title: "fixture", posts: [post], magnets: [], attachments: items, images: [])
    }
    static func require(_ ok: @autoclosure () -> Bool, _ message: String) {
        precondition(ok(), message)
    }
    static func main() async throws {
        let complete = a + "&dn=A%26B.zip&tr=https%3A%2F%2Ftracker.invalid%2Fa%3Fx%3D1%26y%3D2"
        require(ResourceLinkExtractor.links(in: complete.replacingOccurrences(of: "&", with: "&amp;")) == [complete], "magnet parameters must be retained")
        require(ResourceLinkExtractor.links(in: ed.replacingOccurrences(of: "|", with: "&#124;")) == [ed], "numeric entities / ed2k options")
        require(ResourceLinkExtractor.links(in: ed.replacingOccurrences(of: "|", with: "%7C")) == [ed], "Foundation-encoded pipes")
        require(ResourceLinkExtractor.links(in: ed + "\n" + ed) == [ed], "stable dedup")
        require(ResourceLinkExtractor.links(in: "magnet:?xt=urn:btih:bad\ned2k://|file|x|0|bad|/").isEmpty, "invalid hashes")
        let v2 = "magnet:?xt=urn:btmh:1220" + String(repeating: "d", count: 64)
        require(ResourceLinkExtractor.links(in: v2) == [v2], "v2 magnet")
        require(ResourceLinkExtractor.links(in: "magnet:?xt=urn:btih:" + String(repeating: "A", count: 32)).count == 1, "base32 magnet")
        require(ResourceLinkExtractor.links(in: ed.replacingOccurrences(of: "%20", with: " ")) == [ed], "spaces in ed2k filename")

        let archive = attachment("压缩包.txt", "/archive.txt")
        let ordinary = attachment("单集.txt", "/single.txt")
        let excluded = attachment("压缩包_目录树.txt", "/tree.txt")
        let preferred = try await ResourceLinkExtractor.extractResult(detail: detail(a, [archive, ordinary, excluded]), base: base) { url, referer in
            require(referer == base, "page Referer")
            require(url == archive.url, "automatic valid archive must skip ordinary/excluded TXT")
            return b
        }
        require(preferred.links == [b] && preferred.usedArchiveGroup, "attachment label beats dn / body")
        let fallback = try await ResourceLinkExtractor.extractResult(detail: detail(a, [archive, ordinary, excluded]), base: base) { url, _ in
            require(url != excluded.url, "excluded directory tree must never be read")
            if url == archive.url { throw URLError(.notConnectedToInternet) }
            return ed
        }
        require(fallback.links == [a, ed] && fallback.warnings.count == 1, "read failure must warn and fallback")
        let htmlFallback = try await ResourceLinkExtractor.extractResult(detail: detail(a, [archive]), base: base) { _, _ in "<html>login \(b)</html>" }
        require(htmlFallback.links == [a] && htmlFallback.warnings.count == 1, "HTML cannot win archive priority")
        let emptyFallback = try await ResourceLinkExtractor.extractResult(detail: detail(a, [archive]), base: base) { _, _ in "not a resource" }
        require(emptyFallback.links == [a] && emptyFallback.warnings.count == 1, "empty archive group fallback")
        let suffix = try await ResourceLinkExtractor.extractResult(detail: detail(a + "\n" + complete), base: base) { _, _ in preconditionFailure("no TXT") }
        require(suffix.links == [complete], "fallback archive extension uses decoded dn")
        let manual = try await ResourceLinkExtractor.extractResult(detail: detail(a, [archive, ordinary, excluded]), base: base, mode: .manual) { url, _ in
            url == archive.url ? b : ed
        }
        require(manual.links == [a, b, ed] && !manual.usedArchiveGroup, "manual bypasses exclusion and preference")
        let anchor = "<a href='/download.php?id=9' title='打包.txt'>下载</a>"
        let fromHTML = try await ResourceLinkExtractor.extractResult(detail: detail(a + anchor), base: base) { url, _ in
            require(url.path == "/download.php", "relative anchor URL")
            return b
        }
        require(fromHTML.links == [b], "TXT title metadata / relative URL")
        let smallArchive = attachment("links.zip", "/links.zip")
        let opened = try await ResourceLinkExtractor.extractResult(detail: detail(a, [smallArchive]), base: base, dataLoader: { url, referer in
            require(url == smallArchive.url && referer == base, "archive request")
            throw ResourceLinkExtractor.ExtractionError.attachment("fixture archive")
        })
        require(opened.links == [a], "failed small archive falls back")
        let duplicate = try await ResourceLinkExtractor.extractResult(detail: detail(a, [ordinary]), base: base) { _, _ in a }
        require(duplicate.resources.count == 1 && duplicate.resources[0].sources.count == 2, "duplicate retains provenance")
        do {
            _ = try await ResourceLinkExtractor.extractResult(detail: detail("", [archive]), base: base) { _, _ in "" }
            preconditionFailure("empty resources must throw")
        } catch ResourceLinkExtractor.ExtractionError.noValidLinks(let warnings) {
            require(warnings.count == 1, "empty error carries warnings")
        }
        do {
            _ = try await ResourceLinkExtractor.extractResult(detail: detail(a, [archive]), base: base, loader: { _, _ in throw CancellationError() }, dataLoader: { _, _ in throw CancellationError() })
            preconditionFailure("cancellation must propagate")
        } catch is CancellationError {}
        let extensionless = attachment("eD2k", "/forum.php?mod=attachment&aid=fixture")
        let noSuffix = try await ResourceLinkExtractor.extractResult(detail: detail("", [extensionless]), base: base) { url, _ in
            require(url == extensionless.url, "explicit extensionless attachment")
            return ed
        }
        require(noSuffix.links == [ed], "extensionless eD2k metadata is read")
        let relative = try await ResourceLinkExtractor.extractResult(detail: detail("<a href='forum.php?mod=attachment&amp;aid=fixture'>eD2k</a>"), base: base) { url, _ in
            require(ResourceLinkExtractor.isDiscuzAttachment(url), "relative Discuz attachment endpoint")
            return ed
        }
        require(relative.links == [ed], "relative extensionless anchor")
        let page = try await ResourceLinkExtractor.extractResult(detail: detail(a + "<a href='/forum.php?mod=viewthread&amp;tid=9'>eD2k</a><a href='/ordinary'>eD2k</a>"), base: base) { _, _ in
            preconditionFailure("ordinary pages must not be downloaded")
        }
        require(page.links == [a], "ordinary webpage ignored")
        let login = try await ResourceLinkExtractor.extractResult(detail: detail(a, [extensionless]), base: base) { _, _ in
            try ResourceLinkExtractor.attachmentText(Data("<!doctype html><html>login</html>".utf8))
        }
        require(login.links == [a] && login.warnings.count == 1, "extensionless login HTML fallback")
        let binary = try await ResourceLinkExtractor.extractResult(detail: detail(a, [extensionless]), base: base) { _, _ in
            try ResourceLinkExtractor.attachmentText(Data([0x50, 0x4B, 0x03, 0x04, 0, 1]))
        }
        require(binary.links == [a] && binary.warnings.count == 1, "binary fallback")
        let decodedUTF8 = try ResourceLinkExtractor.attachmentText(Data(ed.utf8), mimeType: "application/octet-stream")
        require(decodedUTF8 == ed, "UTF8 octet-stream signature")
        let decodedUTF16 = try ResourceLinkExtractor.attachmentText(ed.data(using: .utf16)!)
        require(decodedUTF16 == ed, "UTF16 BOM")
        do {
            _ = try ResourceLinkExtractor.attachmentText(Data(ed.utf8), mimeType: "text/html")
            preconditionFailure("HTML MIME must be rejected")
        } catch ResourceLinkExtractor.ExtractionError.attachment {}
        let actual = "ed2k://|file|www.98T.la@[AlinaxMei] My best friend's Asian girlfriend got a creampie.mp4|1776335157|F9521F774DC30A5FE980E23DCDEF19C7|/"
        let normalized = actual.replacingOccurrences(of: " ", with: "%20")
        let oldPattern = #"ed2k://(?:\||%7c)file(?:\||%7c)[^\r\n<>\"']*?(?:\||%7c)/"#
        require(HTML.allMatches(oldPattern, in: actual, group: 0).isEmpty, "1.10.11 reproduces apostrophe truncation on supplied real body")
        for variant in [actual, actual.replacingOccurrences(of: "'", with: "&#39;"), actual.replacingOccurrences(of: "'", with: "&apos;"), normalized, normalized.replacingOccurrences(of: "'", with: "%27")] {
            let expected = variant.contains("%27") ? normalized.replacingOccurrences(of: "'", with: "%27") : normalized
            let text = try ResourceLinkExtractor.attachmentText(Data(variant.utf8), mimeType: "application/octet-stream")
            require(ResourceLinkExtractor.links(in: text) == [expected], "real text decoding and field extraction")
            let bodyResult = try await ResourceLinkExtractor.extractResult(detail: detail("<div class='blockcode'><code>" + variant + "</code></div>"), base: base)
            require(bodyResult.links == [expected], "real code block without injected loader")
        }
        let failedAttachment = try await ResourceLinkExtractor.extractResult(detail: detail("<code>" + actual + "</code>", [extensionless]), base: base) { _, _ in
            throw URLError(.notConnectedToInternet)
        }
        require(failedAttachment.links == [normalized] && failedAttachment.warnings.count == 1, "valid real body survives attachment failure")
        for invalid in [actual.replacingOccurrences(of: "|1776335157|", with: "|0|"), actual.replacingOccurrences(of: "|1776335157|", with: "|999999999999999999999999|"), actual.replacingOccurrences(of: "friend's", with: "friend<br>s"), actual.replacingOccurrences(of: "|/", with: "|evil|/"), String(actual.dropLast()), actual.replacingOccurrences(of: "friend's", with: "friend\ns")] {
            require(ResourceLinkExtractor.links(in: invalid).isEmpty, "reject broken or malicious field structure")
        }
        let forbidden = HTTPURLResponse(url: URL(string: "https://forum.invalid/forum.php?aid=SECRET")!, statusCode: 403, httpVersion: nil, headerFields: [:])!
        do {
            try ResourceLinkExtractor.validateAttachmentResponse(forbidden, maximumBytes: ResourceLinkExtractor.maximumTextBytes)
            preconditionFailure("403 accepted")
        } catch {
            let message = ResourceLinkExtractor.safeMessage(error)
            require(message.contains("403") && !message.contains("SECRET") && !message.contains("forum.invalid"), "HTTP status without signed URL")
        }
        require(ResourceLinkExtractor.safeMessage(URLError(.timedOut)).contains("-1001"), "URLError numeric diagnostic")
        let local = URL(string: "http://127.0.0.1:18763/thread")!
        for path in ["ed2k", "redirect", "headers"] {
            let text = try await ResourceLinkExtractor.readTextAttachment(URL(string: "http://127.0.0.1:18763/" + path)!, referer: local)
            require(ResourceLinkExtractor.links(in: text) == [normalized], "production URLSession streaming, redirect and headers")
        }
        for path in ["forbidden", "html", "binary"] {
            do {
                _ = try await ResourceLinkExtractor.readTextAttachment(URL(string: "http://127.0.0.1:18763/" + path)!, referer: local)
                preconditionFailure("production transport accepted permission/binary response")
            } catch ResourceLinkExtractor.ExtractionError.attachment {}
        }
        print("ResourceLinkExtractor offline and production HTTP fixtures passed")
    }
}
