import Foundation

enum NativeSignError: LocalizedError {
    case unavailable, rejected(String), unknown
    var errorDescription: String? {
        switch self {
        case .unavailable: return "签到验证尚未通过，不会提交签到"
        case .rejected(let message): return message
        case .unknown: return "签到结果未知，已停止；请刷新核对，不会自动重试"
        }
    }
}

enum NativeSignProtocol {
    static func ready(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return String(describing: obj["data"] ?? "") == "ok"
    }
    static func outcome(_ json: String) -> Result<String, NativeSignError> {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = Int(String(describing: obj["code"] ?? "")) else { return .failure(.unknown) }
        let message = String(describing: obj["message"] ?? "")
        if code == 200 { return .success(message.isEmpty ? "签到成功" : message) }
        if !message.isEmpty { return .failure(.rejected(message)) }
        return .failure(.unknown)
    }
}

enum NativeFavoriteError: LocalizedError {
    case unavailable, already, rejected(String), unknown
    var errorDescription: String? {
        switch self {
        case .unavailable: return "当前主题没有可确认的收藏表单，请到原帖核对"
        case .already: return "站点确认当前主题已收藏，不会重复提交"
        case .rejected(let message): return message
        case .unknown: return "收藏结果未知，已停止；请到原帖核对，不会自动重发"
        }
    }
}

enum NativeFavoriteProtocol {
    struct Form: Equatable { let action: URL; let fields: [String: String] }
    static func form(_ html: String, base: URL, tid: Int) throws -> Form {
        let text = HTML.plainText(html)
        if text.contains("您已收藏") || text.contains("已经收藏") { throw NativeFavoriteError.already }
        guard let raw = HTML.elements(in: html, tag: "form").first(where: { element in
            guard let action = HTML.attribute("action", in: element),
                  let url = HTML.absURL(action, base: base),
                  url.scheme?.lowercased() == "https", url.host?.lowercased() == base.host?.lowercased(),
                  url.path.hasSuffix("/home.php"),
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
            return items.contains { $0.name == "mod" && $0.value == "spacecp" }
                && items.contains { $0.name == "ac" && $0.value == "favorite" }
                && items.contains { $0.name == "type" && $0.value == "thread" }
                && HTML.queryInt("id", in: url.absoluteString) == tid
        }) else { throw NativeFavoriteError.unavailable }
        guard let action = HTML.absURL(HTML.attribute("action", in: raw) ?? "", base: base) else { throw NativeFavoriteError.unavailable }
        var fields: [String: String] = [:]
        for input in HTML.elements(in: raw, tag: "input") + HTML.elements(in: raw, tag: "textarea") {
            guard let name = HTML.attribute("name", in: input),
                  name.range(of: #"^[A-Za-z][A-Za-z0-9_]{0,39}$"#, options: .regularExpression) != nil,
                  fields[name] == nil else { throw NativeFavoriteError.unavailable }
            fields[name] = HTML.attribute("value", in: input) ?? ""
        }
        guard fields["formhash"]?.isEmpty == false, fields["favoritesubmit"] != nil else { throw NativeFavoriteError.unavailable }
        fields["favoritesubmit"] = "true"
        return Form(action: action, fields: fields)
    }
    static func outcome(_ html: String) -> Result<Void, NativeFavoriteError> {
        let text = HTML.plainText(html)
        if text.contains("您已收藏") || text.contains("已经收藏") { return .failure(.already) }
        if text.contains("收藏成功") || text.contains("信息收藏成功") { return .success(()) }
        if let message = HTML.firstMatch(#"(抱歉[^<。]{0,80})"#, in: text) { return .failure(.rejected(message)) }
        return .failure(.unknown)
    }
}
