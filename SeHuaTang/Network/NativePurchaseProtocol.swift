import Foundation

enum NativePurchaseError: LocalizedError, Equatable {
    case unavailable, alreadyPurchased, rejected(String), unknown
    var errorDescription: String? {
        switch self {
        case .unavailable: return "当前主题没有可确认的购买表单，请到原帖核对"
        case .alreadyPurchased: return "站点确认当前账号已购买，不会重复付款"
        case .rejected(let message): return message
        case .unknown: return "购买结果未知，已停止；请到原帖核对，不会自动重发"
        }
    }
}

enum NativePurchaseProtocol {
    struct Form: Equatable {
        let action: URL
        let fields: [String: String]
    }
    static func form(_ html: String, base: URL, tid: Int) throws -> Form {
        guard let raw = HTML.elements(in: html, tag: "form").first(where: { element in
            guard let action = HTML.attribute("action", in: element),
                  let url = HTML.absURL(action, base: base),
                  url.host?.lowercased() == base.host?.lowercased(),
                  url.scheme?.lowercased() == "https",
                  url.path.hasSuffix("/forum.php"),
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
            return items.contains { $0.name == "mod" && $0.value == "misc" }
                && items.contains { $0.name == "action" && $0.value == "pay" }
                && items.contains { $0.name == "paysubmit" && $0.value == "yes" }
        }) else { throw NativePurchaseError.unavailable }
        guard let action = HTML.absURL(HTML.attribute("action", in: raw) ?? "", base: base) else { throw NativePurchaseError.unavailable }
        var fields: [String: String] = [:]
        for input in HTML.elements(in: raw, tag: "input") {
            guard let name = HTML.attribute("name", in: input),
                  name.range(of: #"^[A-Za-z][A-Za-z0-9_]{0,39}$"#, options: .regularExpression) != nil,
                  fields[name] == nil else { throw NativePurchaseError.unavailable }
            fields[name] = HTML.attribute("value", in: input) ?? ""
        }
        guard fields["formhash"]?.isEmpty == false, fields["tid"] == String(tid), fields["paysubmit"] != nil else { throw NativePurchaseError.unavailable }
        fields["paysubmit"] = "true"
        return Form(action: action, fields: fields)
    }
    static func encode(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return fields.sorted { $0.key < $1.key }.map {
            ($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&").data(using: .utf8)!
    }
    static func outcome(_ html: String) -> Result<Void, NativePurchaseError> {
        let text = HTML.plainText(html)
        if text.contains("您已购买过此主题") || text.contains("您已经购买过此主题") { return .failure(.alreadyPurchased) }
        if text.contains("购买成功") || text.contains("支付成功") || text.contains("主题购买成功") { return .success(()) }
        if let message = HTML.firstMatch(#"(抱歉[^<。]{0,80})"#, in: text) { return .failure(.rejected(message)) }
        return .failure(.unknown)
    }
}
