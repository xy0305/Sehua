import Foundation

private struct HTMLTag {
    let name: String
    let closing: Bool
    let empty: Bool
    let raw: String
    let range: Range<String.Index>
}

/// Shared request generation guard: refresh never commits a stale or different-source result.
struct ThreadRequestGate {
    private(set) var generation = 0
    private(set) var source: URL?
    private(set) var tid: Int?
    private(set) var busy = false
    mutating func begin(tid: Int, source: URL) -> Int? {
        guard !busy else { return nil }
        generation += 1
        self.tid = tid
        self.source = source
        busy = true
        return generation
    }
    func accepts(_ token: Int, tid: Int, source: URL) -> Bool {
        busy && generation == token && self.tid == tid && self.source == source
    }
    mutating func finish(_ token: Int) {
        if generation == token { busy = false }
    }
    mutating func invalidate() { generation += 1; busy = false }
}

enum HTML {
    static func unescape(_ s: String) -> String {
        let decoded = s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br />", with: "\n")
        guard let regex = try? NSRegularExpression(pattern: #"&#(x[0-9a-f]+|[0-9]+);"#, options: [.caseInsensitive]) else { return decoded }
        var result = decoded
        for match in regex.matches(in: decoded, range: NSRange(decoded.startIndex..., in: decoded)).reversed() {
            guard let range = Range(match.range, in: result), let valueRange = Range(match.range(at: 1), in: decoded) else { continue }
            let value = String(decoded[valueRange])
            let number = value.lowercased().hasPrefix("x") ? UInt32(value.dropFirst(), radix: 16) : UInt32(value)
            if let number = number, let scalar = UnicodeScalar(number) { result.replaceSubrange(range, with: String(scalar)) }
        }
        return result
    }

    static func stripTags(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"<style[\s\S]*?</style>"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        t = unescape(t)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func firstMatch(_ pattern: String, in text: String, group: Int = 1) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, options: [], range: range), m.numberOfRanges > group else { return nil }
        guard let r = Range(m.range(at: group), in: text) else { return nil }
        return String(text[r])
    }

    static func allMatches(_ pattern: String, in text: String, group: Int = 1) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, options: [], range: range).compactMap { m in
            guard m.numberOfRanges > group, let r = Range(m.range(at: group), in: text) else { return nil }
            return String(text[r])
        }
    }

    static func absURL(_ href: String, base: URL) -> URL? {
        let h = unescape(href).trimmingCharacters(in: .whitespacesAndNewlines)
        if h.isEmpty || h.hasPrefix("javascript:") || h.hasPrefix("#") { return nil }
        return URL(string: h, relativeTo: base)?.absoluteURL
    }

    static func queryInt(_ name: String, in url: String) -> Int? {
        let u = unescape(url)
        if let m = firstMatch("(?:[?&]" + name + "=)(\\d+)", in: u) { return Int(m) }
        if name == "tid", let m = firstMatch("thread-(\\d+)", in: u) { return Int(m) }
        if name == "fid", let m = firstMatch("forum-(\\d+)", in: u) { return Int(m) }
        return nil
    }
    private static func tags(_ html: String) -> [HTMLTag] {
        // Comments and raw-text elements are consumed as one token, so apparent tags
        // in JavaScript, CSS or comments cannot close a message container.
        let pattern = #"<!--[\s\S]*?-->|<(script|style)\b[^>]*>[\s\S]*?</\1\s*>|</?[A-Za-z][A-Za-z0-9:_-]*(?:\s+(?:[^>\"']|\"[^\"]*\"|'[^']*')*)?\s*/?>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let range = Range(match.range, in: html) else { return nil }
            let raw = String(html[range])
            guard let name = firstMatch(#"^</?([A-Za-z][A-Za-z0-9:_-]*)"#, in: raw) else { return nil }
            return HTMLTag(name: name.lowercased(), closing: raw.hasPrefix("</"), empty: raw.hasSuffix("/>"), raw: raw, range: range)
        }
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        guard let opening = firstMatch(#"^</?[A-Za-z][A-Za-z0-9:_-]*(?:\s+(?:[^>\"']|\"[^\"]*\"|'[^']*')*)?\s*/?>"#, in: tag, group: 0) else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"(?:\s)"# + escaped + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        for group in 1...3 {
            if let value = firstMatch(pattern, in: opening, group: group) { return unescape(value) }
        }
        return nil
    }

    static func hasClass(_ name: String, in tag: String) -> Bool {
        (attribute("class", in: tag) ?? "").split(whereSeparator: { $0.isWhitespace }).contains { $0 == name }
    }

    /// Returns full, balanced elements (or their contents), never an unbounded page suffix.
    static func elements(in html: String, tag name: String? = nil, className: String? = nil, idPrefix: String? = nil, inner: Bool = false) -> [String] {
        elements(in: html, inner: inner) { tag in
            (name == nil || firstMatch(#"^<([A-Za-z][A-Za-z0-9:_-]*)"#, in: tag)?.lowercased() == name?.lowercased())
                && (className == nil || hasClass(className!, in: tag))
                && (idPrefix == nil || (attribute("id", in: tag) ?? "").hasPrefix(idPrefix!))
        }
    }

    /// A single ordered scan for alternative selectors; outer matches consume nested matches.
    static func elements(in html: String, inner: Bool = false, matching: (String) -> Bool) -> [String] {
        let tokens = tags(html)
        var result: [String] = []
        var consumedUntil = html.startIndex
        for (index, token) in tokens.enumerated() {
            guard !token.closing, token.range.lowerBound >= consumedUntil,
                  matching(token.raw) else { continue }
            if token.empty || ["img", "input", "br", "hr", "meta", "link"].contains(token.name) {
                result.append(inner ? "" : token.raw)
                consumedUntil = token.range.upperBound
                continue
            }
            var depth = 1
            for end in tokens.dropFirst(index + 1) where end.name == token.name {
                if end.closing { depth -= 1 } else if !end.empty { depth += 1 }
                if depth == 0 {
                    let range = inner ? token.range.upperBound..<end.range.lowerBound : token.range.lowerBound..<end.range.upperBound
                    result.append(String(html[range]))
                    consumedUntil = end.range.upperBound
                    break
                }
            }
        }
        return result
    }

    static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"(?is)<(script|style)\b[^>]*>[\s\S]*?</\1\s*>|<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)<br\b[^>]*>|</?(?:p|div|li|blockquote|h[1-6]|tr|section|pre)\b[^>]*>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return unescape(text).components(separatedBy: .newlines).map {
            $0.replacingOccurrences(of: #"[^\S\r\n]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n").replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct Inline: Hashable {
        var text: String
        var href: String?
        var url: URL?
        var alignment: String = "left"
        var color: String? = nil
        var bold: Bool = false
    }

    enum Content: Hashable {
        case richText([Inline])
        case text(String)
        case image(URL)
        case emoticon(Emoticon)
        case attachment(Attachment)
        case attachmentIcon(URL)
    }

    /// Semantic Discuz smileys only; query strings and unrelated static assets are not evidence.
    struct Emoticon: Hashable {
        let url: URL
        let width: Double
        let height: Double
        let alt: String
    }

    static func emoticon(in tag: String, url: URL) -> Emoticon? {
        let classes = (attribute("class", in: tag) ?? "").lowercased().split(whereSeparator: { $0.isWhitespace })
        let path = url.path.lowercased()
        let smileyPath = path.hasPrefix("/static/image/smiley/") || path.contains("/static/image/smiley/")
        let semantic = attribute("smilieid", in: tag) != nil || classes.contains("smilie") || classes.contains("smiley")
        guard smileyPath || semantic else { return nil }
        func dimension(_ name: String) -> Double? {
            guard let raw = attribute(name, in: tag), let value = Double(raw), value.isFinite, value > 0 else { return nil }
            return value
        }
        let w = dimension("width")
        let h = dimension("height")
        let width = w ?? h ?? 28
        let height = h ?? w ?? 28
        let scale = min(1, 32 / max(width, height))
        return Emoticon(url: url, width: width * scale, height: height * scale, alt: attribute("alt", in: tag) ?? "表情")
    }

    struct Attachment: Hashable {
        let url: URL
        let name: String
        var size: String? = nil
        var downloads: String? = nil
    }

    static func isAttachmentIcon(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return path.contains("/static/image/filetype/") || path.contains("/images/attachicons/")
    }

    private static func attachmentURL(_ tag: String, base: URL) -> URL? {
        guard let href = attribute("href", in: tag), let url = absURL(href, base: base),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let discuz = query.contains { $0.name == "mod" && $0.value == "attachment" }
        let marked = hasClass("attachfile", in: tag) || (attribute("id", in: tag) ?? "").hasPrefix("attach_")
        return discuz || marked ? url : nil
    }

    /// Balanced attachment components only; no generic static/image or size heuristic.
    static func attachmentMarkup(in source: String, base: URL) -> (html: String, files: [Attachment]) {
        var html = source
        var files: [Attachment] = []
        var seen = Set<String>()
        func replace(_ component: String) {
            let anchors = elements(in: component, tag: "a")
            let candidates = anchors.compactMap { anchor -> (URL, String)? in
                guard let url = attachmentURL(anchor, base: base) else { return nil }
                return (url, stripTags(anchor))
            }
            guard let selected = candidates.first(where: { !$0.1.isEmpty }) ?? candidates.first else { return }
            let text = plainText(component)
            let item = Attachment(url: selected.0, name: selected.1.isEmpty ? "附件" : selected.1,
                size: firstMatch(#"(?i)(\d+(?:\.\d+)?\s*(?:Bytes|KB|MB|GB|KiB|MiB|GiB))\b"#, in: text),
                downloads: firstMatch(#"下载(?:次数)?\s*[:：]?\s*(\d+)"#, in: text))
            let marker: String
            if seen.insert(item.url.absoluteString).inserted {
                marker = "<shtattachment index='\(files.count)'/>"
                files.append(item)
            } else { marker = "" }
            if let range = html.range(of: component) { html.replaceSubrange(range, with: marker) }
        }
        for component in elements(in: html, matching: { tag in
            ["tattl", "attnm", "attachfile"].contains { hasClass($0, in: tag) }
                || (attribute("id", in: tag) ?? "").hasPrefix("attachdiv_")
        }) { replace(component) }
        for anchor in elements(in: html, tag: "a") where attachmentURL(anchor, base: base) != nil { replace(anchor) }
        return (html, files)
    }

    /// Split at actual image tags, retaining text/image/text order and lazy image URLs.
    static func orderedContent(in source: String, base: URL) -> [Content] {
        let markup = attachmentMarkup(in: source, base: base)
        let html = markup.html.replacingOccurrences(of: #"(?is)<(script|style)\b[^>]*>[\s\S]*?</\1\s*>|<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
        var result: [Content] = []
        var runs: [Inline] = []
        var href: String?
        var style = Inline(text: "")
        var stack: [(String, Inline)] = []
        var cursor = html.startIndex
        func append(_ text: String) {
            let value = unescape(text)
            guard !value.isEmpty else { return }
            var run = style
            run.text = value
            run.href = href
            run.url = href.flatMap { absURL($0, base: base) }
            runs.append(run)
        }
        func flush() {
            if runs.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                if runs.allSatisfy({ $0.href == nil && $0.alignment == "left" && $0.color == nil && !$0.bold }) {
                    result.append(.text(runs.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)))
                } else { result.append(.richText(runs)) }
            }
            runs = []
        }
        for token in tags(html) {
            append(String(html[cursor..<token.range.lowerBound]))
            switch token.name {
            case "shtattachment":
                flush()
                if let index = attribute("index", in: token.raw).flatMap(Int.init), markup.files.indices.contains(index) { result.append(.attachment(markup.files[index])) }
            case "a": href = token.closing ? nil : attribute("href", in: token.raw)
            case "img":
                flush()
                if let url = imageURLs(in: token.raw, base: base, excludingDecorations: false).first {
                    if let smiley = emoticon(in: token.raw, url: url) { result.append(.emoticon(smiley)) }
                    else if isAttachmentIcon(url) { result.append(.attachmentIcon(url)) }
                    else { result.append(.image(url)) }
                }
            case "br": append("\n")
            case "p", "div", "center", "li", "blockquote", "tr", "section", "pre", "font", "span", "b", "strong":
                let block = ["p", "div", "center", "li", "blockquote", "tr", "section", "pre"].contains(token.name)
                if block { flush() }
                if token.closing {
                    if let index = stack.lastIndex(where: { $0.0 == token.name }) {
                        style = stack[index].1
                        stack.removeSubrange(index...)
                    }
                } else {
                    stack.append((token.name, style))
                    let css = attribute("style", in: token.raw) ?? ""
                    if token.name == "center" { style.alignment = "center" }
                    if let alignment = attribute("align", in: token.raw) ?? firstMatch(#"(?:^|;)\s*text-align\s*:\s*(left|center|right)"#, in: css) { style.alignment = alignment.lowercased() }
                    if let color = attribute("color", in: token.raw) ?? firstMatch(#"(?:^|;)\s*color\s*:\s*([^;]+)"#, in: css) { style.color = color.trimmingCharacters(in: .whitespaces) }
                    if ["b", "strong"].contains(token.name) || css.lowercased().contains("font-weight:bold") || css.lowercased().contains("font-weight: bold") { style.bold = true }
                }
            default: break
            }
            cursor = token.range.upperBound
        }
        append(String(html[cursor...]))
        flush()
        return result
    }

    static func imageURLs(in html: String, base: URL, excludingDecorations: Bool = true) -> [URL] {
        var seen = Set<String>()
        return elements(in: attachmentMarkup(in: html, base: base).html, tag: "img").compactMap { tag in
            for key in ["zoomfile", "file", "data-original", "data-src", "src"] {
                guard let value = attribute(key, in: tag), let url = absURL(value, base: base),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
                let path = url.path.lowercased()
                if excludingDecorations && isAttachmentIcon(url) { continue }
                if excludingDecorations && (emoticon(in: tag, url: url) != nil || path.contains("/uc_server/") || path.contains("/avatar") || path.contains("noavatar") || path.contains("/static/image/") || path.contains("/smiley/")) { continue }
                // Only one URL per tag; never choose the last matching attribute by greediness.
                return seen.insert(url.absoluteString).inserted ? url : nil
            }
            return nil
        }
    }

}
