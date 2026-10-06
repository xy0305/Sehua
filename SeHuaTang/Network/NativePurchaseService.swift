import Foundation
import WebKit

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
