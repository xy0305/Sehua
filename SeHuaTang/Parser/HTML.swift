import Foundation

private struct HTMLTag {
    let name: String
    let closing: Bool
    let empty: Bool
    let raw: String
    let range: Range<String.Index>
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

    enum Content: Hashable {
        case text(String)
        case image(URL)
    }

    /// Split at actual image tags, retaining text/image/text order and lazy image URLs.
    static func orderedContent(in html: String, base: URL) -> [Content] {
        var result: [Content] = []
        var cursor = html.startIndex
        for token in tags(html) where token.name == "img" && !token.closing {
            let text = plainText(String(html[cursor..<token.range.lowerBound]))
            if !text.isEmpty { result.append(.text(text)) }
            if let url = imageURLs(in: token.raw, base: base).first { result.append(.image(url)) }
            cursor = token.range.upperBound
        }
        let text = plainText(String(html[cursor...]))
        if !text.isEmpty { result.append(.text(text)) }
        return result
    }

    static func imageURLs(in html: String, base: URL, excludingDecorations: Bool = true) -> [URL] {
        var seen = Set<String>()
        return elements(in: html, tag: "img").compactMap { tag in
            for key in ["zoomfile", "file", "data-original", "data-src", "src"] {
                guard let value = attribute(key, in: tag), let url = absURL(value, base: base),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
                let path = url.path.lowercased()
                if excludingDecorations && (path.contains("/uc_server/") || path.contains("/avatar") || path.contains("noavatar") || path.contains("/static/image/") || path.contains("/smiley/")) { continue }
                // Only one URL per tag; never choose the last matching attribute by greediness.
                return seen.insert(url.absoluteString).inserted ? url : nil
            }
            return nil
        }
    }

}
