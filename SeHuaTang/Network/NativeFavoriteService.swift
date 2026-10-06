import Foundation

@MainActor final class NativeFavoriteService: ObservableObject {
    static let shared = NativeFavoriteService()
    @Published private(set) var sending = Set<String>()
    private let defaults = UserDefaults.standard
    private func key(_ host: String, _ tid: Int) -> String { "sht.favorite.pending.\(host).\(tid)" }
    func locked(host: String, tid: Int) -> Bool { defaults.bool(forKey: key(host, tid)) }
    func favorite(session: WebSession, tid: Int) async throws {
        let identity = key(session.host, tid)
        guard !sending.contains(identity), !locked(host: session.host, tid: tid) else { throw NativeFavoriteError.unknown }
        sending.insert(identity)
        defer { sending.remove(identity) }
        let source = session.url("home.php?mod=spacecp&ac=favorite&type=thread&id=\(tid)&mobile=2")
        let html = try await session.fetchHTML(source.absoluteString, interactive: true)
        if HTML.plainText(html).contains("您已收藏") || HTML.plainText(html).contains("已经收藏") { throw NativeFavoriteError.already }
        let form = try NativeFavoriteProtocol.form(html, base: session.baseURL, tid: tid)
        defaults.set(true, forKey: identity)
        do {
            let text = try await post(form, session: session, referer: source)
            switch NativeFavoriteProtocol.outcome(text) {
            case .success: defaults.set(false, forKey: identity)
            case .failure(let error):
                if case .unknown = error {} else { defaults.set(false, forKey: identity) }
                throw error
            }
        } catch let error as NativeFavoriteError { throw error }
        catch { throw NativeFavoriteError.unknown }
    }
    private func post(_ form: NativeFavoriteProtocol.Form, session: WebSession, referer: URL) async throws -> String {
        let cookies = await session.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30
        let transport = URLSession(configuration: configuration, delegate: PurchaseRedirectGuard(), delegateQueue: nil)
        defer { transport.invalidateAndCancel() }
        var request = URLRequest(url: form.action)
        request.httpMethod = "POST"
        request.httpBody = NativePurchaseProtocol.encode(form.fields)
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(session.baseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue(session.webView.customUserAgent, forHTTPHeaderField: "User-Agent")
        let applicable = cookies.filter {
            let domain = $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            let host = session.baseURL.host!.lowercased()
            return (host == domain || host.hasSuffix("." + domain)) && form.action.path.hasPrefix($0.path)
        }
        for (name, value) in HTTPCookie.requestHeaderFields(with: applicable) { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else { throw NativeFavoriteError.unknown }
        return text
    }
}
