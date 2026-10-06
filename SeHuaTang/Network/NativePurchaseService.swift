import Foundation
import WebKit

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

@MainActor final class NativePurchaseService: ObservableObject {
    static let shared = NativePurchaseService()
    @Published private(set) var sending = Set<String>()
    private let defaults = UserDefaults.standard
    private func key(_ host: String, _ tid: Int) -> String { "sht.purchase.pending.\(host).\(tid)" }
    func locked(host: String, tid: Int) -> Bool { defaults.bool(forKey: key(host, tid)) }
    func purchase(session: WebSession, tid: Int, source: URL) async throws {
        let identity = key(session.host, tid)
        guard !sending.contains(identity), !locked(host: session.host, tid: tid) else { throw NativePurchaseError.unknown }
        sending.insert(identity)
        defer { sending.remove(identity) }
        let html = try await session.fetchHTML(source.absoluteString, interactive: true)
        switch DiscuzParser.purchaseState(html, tid: tid, base: source) {
        case .purchased: throw NativePurchaseError.alreadyPurchased
        case .required: break
        default: throw NativePurchaseError.unavailable
        }
        let form = try NativePurchaseProtocol.form(html, base: session.baseURL, tid: tid)
        let cookies = await session.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30
        let transport = URLSession(configuration: configuration, delegate: ReplyRedirectGuard(), delegateQueue: nil)
        defer { transport.invalidateAndCancel() }
        var request = URLRequest(url: form.action)
        request.httpMethod = "POST"
        request.httpBody = NativePurchaseProtocol.encode(form.fields)
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(session.baseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(source.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue(session.webView.customUserAgent, forHTTPHeaderField: "User-Agent")
        let applicable = cookies.filter {
            let domain = $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            let host = session.baseURL.host!.lowercased()
            return (host == domain || host.hasSuffix("." + domain)) && form.action.path.hasPrefix($0.path)
        }
        for (name, value) in HTTPCookie.requestHeaderFields(with: applicable) { request.setValue(value, forHTTPHeaderField: name) }
        defaults.set(true, forKey: identity)
        do {
            let (data, response) = try await transport.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let text = String(data: data, encoding: .utf8) else { throw NativePurchaseError.unknown }
            switch NativePurchaseProtocol.outcome(text) {
            case .success: defaults.set(false, forKey: identity)
            case .failure(let error):
                if case .unknown = error {} else { defaults.set(false, forKey: identity) }
                throw error
            }
        } catch let error as NativePurchaseError { throw error }
        catch { throw NativePurchaseError.unknown }
    }
}
