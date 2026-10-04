import Foundation

/// Pure production parser; never executes site scripts or persists credentials.
enum NativeReplyProtocol {
    struct DispatchGate {
        let defaults: UserDefaults
        func locked(_ key: String) -> Bool { defaults.bool(forKey: key) }
        func begin(_ key: String) throws {
            guard !locked(key) else { throw ReplyError.unknown }
            defaults.set(true, forKey: key)
        }
        func resolved(_ key: String) { defaults.removeObject(forKey: key) }
    }
    struct Form { let action: URL; var fields: [String: String] }
    struct Success { let url: URL; let pid: Int; let page: Int }
    enum ReplyError: LocalizedError {
        case unsupported, unknown, rejected
        var errorDescription: String? {
            switch self {
            case .unsupported: return "表单需要验证、引用或不支持的字段，请在应用内网页处理。"
            case .unknown: return "发送结果未知，可能已发布。请先查原帖；草稿已保留，不会自动重发。"
            case .rejected: return "站点明确拒绝回复（可能权限、间隔或内容限制）。请检查原帖或网页提示后重新确认。"
            }
        }
    }
    static func safe(_ url: URL, base: URL, tid: Int, fid: Int? = nil) -> Bool {
        guard url.scheme == "https", url.host?.lowercased() == base.host?.lowercased(), url.port == base.port,
              url.user == nil, url.password == nil, url.path == "/forum.php",
              let c = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return false }
        let q = c.queryItems ?? []
        guard q.filter({ $0.name == "tid" }).count == 1, q.first(where: { $0.name == "tid" })?.value == String(tid) else { return false }
        if let fid { return q.filter({ $0.name == "fid" }).count == 1 && q.first(where: { $0.name == "fid" })?.value == String(fid) }
        return true
    }
    static func form(_ html: String, base: URL, tid: Int, fid: Int) throws -> Form {
        guard HTML.firstMatch(#"(?is)<(?:input|textarea|select)\b[^>]*\bname\s*=\s*[\"']?(?:seccode|secqa|captcha)"#, in: html, group: 0) == nil,
              HTML.firstMatch(#"(?is)<(?:img|div|iframe)\b[^>]*(?:id|src)\s*=\s*[\"'][^\"']*(?:seccode|captcha|challenge)"#, in: html, group: 0) == nil else { throw ReplyError.unsupported }
        let forms = HTML.allMatches(#"(?is)<form\b[^>]*>.*?</form>"#, in: html, group: 0)
        for markup in forms {
            guard let raw = HTML.attribute("action", in: markup), let action = URL(string: raw, relativeTo: base)?.absoluteURL,
                  safe(action, base: base, tid: tid, fid: fid) else { continue }
            let q = URLComponents(url: action, resolvingAgainstBaseURL: true)?.queryItems ?? []
            guard q.first(where: { $0.name == "mod" })?.value == "post", q.first(where: { $0.name == "action" })?.value == "reply" else { continue }
            var fields: [String: String] = [:]
            let allowed: Set<String> = ["formhash", "handlekey", "noticeauthor", "noticetrimstr", "noticeauthormsg", "usesig", "subject", "message", "replysubmit", "posttime", "wysiwyg", "fid", "tid"]
            for tag in HTML.allMatches(#"(?is)<input\b[^>]*>"#, in: markup, group: 0) {
                guard let name = HTML.attribute("name", in: tag) else { continue }
                let type = (HTML.attribute("type", in: tag) ?? "text").lowercased()
                if ["submit", "button", "reset"].contains(type) { continue }
                if type == "checkbox" && HTML.firstMatch(#"(?i)\bchecked\b"#, in: tag, group: 0) == nil { continue }
                guard allowed.contains(name), fields[name] == nil else { throw ReplyError.unsupported }
                fields[name] = HTML.attribute("value", in: tag) ?? ""
            }
            for tag in HTML.allMatches(#"(?is)<(?:textarea|select)\b[^>]*>"#, in: markup, group: 0) {
                if let name = HTML.attribute("name", in: tag), name != "message" { throw ReplyError.unsupported }
            }
            guard let hash = fields["formhash"], !hash.isEmpty, hash.count <= 128,
                  ["noticeauthor", "noticetrimstr", "noticeauthormsg", "subject"].allSatisfy({ (fields[$0] ?? "").isEmpty }),
                  fields["tid"].map({ $0 == String(tid) }) ?? true,
                  fields["fid"].map({ $0 == String(fid) }) ?? true else { throw ReplyError.unsupported }
            for name in ["noticeauthor", "noticetrimstr", "noticeauthormsg", "subject"] { fields[name] = "" }
            fields["handlekey"] = "reply"
            fields["usesig"] = fields["usesig"] ?? "1"
            var components = URLComponents(url: action, resolvingAgainstBaseURL: true)!
            var items = (components.queryItems ?? []).filter { !["infloat", "inajax", "replysubmit"].contains($0.name) }
            items += [URLQueryItem(name: "infloat", value: "yes"), URLQueryItem(name: "inajax", value: "1"), URLQueryItem(name: "replysubmit", value: "yes")]
            components.queryItems = items
            return Form(action: components.url!, fields: fields)
        }
        throw ReplyError.unsupported
    }
    static func encode(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func escaped(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed)! }
        return Data(fields.keys.sorted().map { escaped($0) + "=" + escaped(fields[$0]!) }.joined(separator: "&").utf8)
    }
    static func success(_ xml: String, base: URL, tid: Int) throws -> Success {
        guard xml.count < 262144, let payload = HTML.firstMatch(#"(?s)^\s*(?:<\?xml[^>]*>\s*)?<root>\s*<!\[CDATA\[(.*?)\]\]>\s*</root>\s*$"#, in: xml) else { throw ReplyError.unknown }
        guard let urlText = HTML.firstMatch(#"succeedhandle_reply\(\s*'([^'\\]+)'\s*,"#, in: payload),
              let url = URL(string: HTML.unescape(urlText), relativeTo: base)?.absoluteURL, safe(url, base: base, tid: tid),
              let pid = HTML.queryInt("pid", in: url.absoluteString), pid > 0,
              let object = HTML.firstMatch(#"succeedhandle_reply\([^\n]*?,\s*\{([^}]+)\}\s*\)"#, in: payload),
              HTML.firstMatch(#"'tid'\s*:\s*'(\d+)'"#, in: object) == String(tid),
              HTML.firstMatch(#"'pid'\s*:\s*'(\d+)'"#, in: object) == String(pid) else {
            if !payload.contains("succeedhandle_reply"), payload.contains("errorhandle_reply") || payload.contains("alert_error") { throw ReplyError.rejected }
            throw ReplyError.unknown
        }
        return Success(url: url, pid: pid, page: HTML.queryInt("page", in: url.absoluteString) ?? 1)
    }
}
