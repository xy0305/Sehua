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
        case diagnostic(String)
        var errorDescription: String? {
            switch self {
            case .unsupported: return "未找到同主题、同版块的安全回复表单，请在应用内网页处理。"
            case .diagnostic(let reason): return reason + "，请在应用内网页处理。"
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
    static func form(_ html: String, base: URL, tid: Int, fid: Int, emptyFileInputs: Set<String> = []) throws -> Form {
        // Strict, bounded Discuz XML envelope; no entities, DTD, or script execution.
        guard html.utf8.count < 1_048_576, !html.lowercased().contains("<!doctype"), !html.lowercased().contains("<!entity") else { throw ReplyError.unsupported }
        var source = html
        if html.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<?xml") || html.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<root>") {
            guard let payload = HTML.firstMatch(#"(?s)^\s*(?:<\?xml[^>]*>\s*)?<root>\s*<!\[CDATA\[(.*?)\]\]>\s*</root>\s*$"#, in: html) else { throw ReplyError.unsupported }
            source = payload
        }
        // Only live markup in the selected reply form is relevant. Script strings and
        // templates elsewhere in Discuz pages do not imply a required challenge.
        let html = source.replacingOccurrences(of: #"(?is)<script\b[^>]*>.*?</script>|<!--.*?-->|<template\b[^>]*>.*?</template>"#, with: "", options: .regularExpression)
        let forms = HTML.allMatches(#"(?is)<form\b[^>]*>.*?</form>"#, in: html, group: 0)
        for markup in forms {
            guard let raw = HTML.attribute("action", in: markup), let action = URL(string: raw, relativeTo: base)?.absoluteURL,
                  safe(action, base: base, tid: tid, fid: fid) else { continue }
            guard HTML.attribute("method", in: markup)?.lowercased() == "post" else { throw ReplyError.diagnostic("回复表单方法不支持") }
            let q = URLComponents(url: action, resolvingAgainstBaseURL: true)?.queryItems ?? []
            guard q.first(where: { $0.name == "mod" })?.value == "post", q.first(where: { $0.name == "action" })?.value == "reply" else { continue }
            if HTML.firstMatch(#"(?is)<(?:input|textarea|select)\b[^>]*\bname\s*=\s*[\"']?(?:seccode|secqa|captcha)"#, in: markup, group: 0) != nil ||
                HTML.firstMatch(#"(?is)<(?:img|div|iframe)\b[^>]*(?:id|src)\s*=\s*[\"'][^\"']*(?:seccode|captcha|challenge)"#, in: markup, group: 0) != nil {
                throw ReplyError.diagnostic("当前回复表单存在验证码或安全验证")
            }
            var fields: [String: String] = [:]
            func fieldError(_ name: String, _ kind: String) -> ReplyError {
                // Never display an arbitrary server-provided value or unbounded name.
                let safeName = name.range(of: #"^[A-Za-z][A-Za-z0-9_]{0,39}$"#, options: .regularExpression) != nil ? name : "未识别字段"
                return .diagnostic(kind + "（" + safeName + "）")
            }
            let allowed: Set<String> = ["formhash", "handlekey", "noticeauthor", "noticetrimstr", "noticeauthormsg", "usesig", "subject", "message", "replysubmit", "posttime", "wysiwyg", "fid", "tid", "sechash", "from"]
            for tag in HTML.allMatches(#"(?is)<input\b[^>]*>"#, in: markup, group: 0) {
                guard let name = HTML.attribute("name", in: tag) else { continue }
                let type = (HTML.attribute("type", in: tag) ?? "text").lowercased()
                if HTML.firstMatch(#"(?i)\sdisabled(?:\s|=|/?>)"#, in: tag, group: 0) != nil { continue }
                if ["submit", "button", "reset"].contains(type) { continue }
                if type == "checkbox" && HTML.firstMatch(#"(?i)\bchecked\b"#, in: tag, group: 0) == nil { continue }
                if type == "file" {
                    guard name == "Filedata", emptyFileInputs.contains(name),
                          (HTML.attribute("value", in: tag) ?? "").isEmpty,
                          HTML.firstMatch(#"(?i)\srequired(?:\s|=|/?>)"#, in: tag, group: 0) == nil else {
                        throw fieldError(name, "附件上传不支持或未确认文件为空")
                    }
                    // Text-only request: omit only this verified optional empty upload.
                    continue
                }
                guard allowed.contains(name) else { throw fieldError(name, "回复表单含不支持的字段") }
                guard fields[name] == nil else { throw fieldError(name, "回复表单含重复字段") }
                guard ["hidden", "text", "checkbox"].contains(type) else { throw fieldError(name, "回复表单控件类型不支持") }
                fields[name] = HTML.attribute("value", in: tag) ?? ""
            }
            for tag in HTML.allMatches(#"(?is)<(textarea|select)\b[^>]*>.*?</\1\s*>"#, in: markup, group: 0) {
                if HTML.firstMatch(#"(?i)\sdisabled(?:\s|=|/?>)"#, in: String(tag.prefix(while: { $0 != ">" })) + ">", group: 0) != nil { continue }
                guard let name = HTML.attribute("name", in: tag) else { continue }
                guard tag.lowercased().hasPrefix("<textarea"), ["message", "subject", "noticeauthor", "noticetrimstr", "noticeauthormsg"].contains(name) else { throw fieldError(name, "回复表单含不支持的控件") }
                guard fields[name] == nil else { throw fieldError(name, "回复表单含重复字段") }
                fields[name] = HTML.unescape(HTML.firstMatch(#"(?is)^[^>]*>(.*?)</textarea\s*>$"#, in: tag) ?? "")
            }
            guard let hash = fields["formhash"], !hash.isEmpty, hash.count <= 128 else { throw ReplyError.diagnostic("回复表单缺少有效的 formhash") }
            for name in ["noticeauthor", "noticetrimstr", "noticeauthormsg"] where !(fields[name] ?? "").isEmpty {
                throw fieldError(name, "当前表单为引用回复")
            }
            guard (fields["subject"] ?? "").isEmpty else { throw fieldError("subject", "回复表单含非空标题") }
            guard (fields["sechash"] ?? "").isEmpty else { throw fieldError("sechash", "当前回复需要安全验证") }
            guard (fields["from"] ?? "").isEmpty else { throw fieldError("from", "回复表单含不支持的来源语义") }
            for name in ["usesig", "wysiwyg"] {
                if let value = fields[name], !["0", "1"].contains(value) { throw fieldError(name, "回复表单字段值不支持") }
            }
            guard fields["tid"].map({ $0 == String(tid) }) ?? true,
                  fields["fid"].map({ $0 == String(fid) }) ?? true else { throw ReplyError.diagnostic("回复表单主题或版块不匹配") }
            for name in ["noticeauthor", "noticetrimstr", "noticeauthormsg", "subject"] { fields[name] = "" }
            fields["handlekey"] = "reply"
            fields["usesig"] = fields["usesig"] ?? "0"
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
