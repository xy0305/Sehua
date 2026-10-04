import Foundation
import Combine
import WebKit

private final class ReplyRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // A POST must never be replayed, nor carry cookies to a redirect target.
        completionHandler(nil)
    }
}

@MainActor final class NativeReplyService: ObservableObject {
    static let shared = NativeReplyService()
    @Published private(set) var sending: Set<String> = []
    private let defaults = UserDefaults.standard
    private func key(_ host: String, _ tid: Int) -> String { "sht.reply.pending.\(host).\(tid)" }
    func locked(host: String, tid: Int) -> Bool { defaults.bool(forKey: key(host, tid)) }
    func submit(session: WebSession, tid: Int, fid: Int, message: String) async throws -> NativeReplyProtocol.Success {
        let base = session.baseURL
        let identity = key(session.host, tid)
        guard !sending.contains(identity), !locked(host: session.host, tid: tid) else { throw NativeReplyProtocol.ReplyError.unknown }
        sending.insert(identity)
        defer { sending.remove(identity) }
        // GET only. Re-fetch dynamic credentials at the actual user-confirmed send.
        let url = session.url("forum.php?mod=post&action=reply&fid=\(fid)&tid=\(tid)&infloat=yes")
        let html = try await session.fetchHTML(url.absoluteString)
        guard session.baseURL == base, session.webView.url.map({ NativeReplyProtocol.safe($0, base: base, tid: tid, fid: fid) }) == true else { throw NativeReplyProtocol.ReplyError.unsupported }
        var form = try NativeReplyProtocol.form(html, base: base, tid: tid, fid: fid)
        form.fields["message"] = message
        let cookies = await session.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 35
        let transport = URLSession(configuration: configuration, delegate: ReplyRedirectGuard(), delegateQueue: nil)
        defer { transport.invalidateAndCancel() }
        var request = URLRequest(url: form.action)
        request.httpMethod = "POST"
        request.httpBody = NativeReplyProtocol.encode(form.fields)
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(base.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(url.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue(session.webView.customUserAgent, forHTTPHeaderField: "User-Agent")
        let applicable = cookies.filter {
            let domain = $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            let host = base.host!.lowercased()
            return (host == domain || host.hasSuffix("." + domain)) && form.action.path.hasPrefix($0.path) && ($0.expiresDate.map { $0 > Date() } ?? true)
        }
        for (name, value) in HTTPCookie.requestHeaderFields(with: applicable) { request.setValue(value, forHTTPHeaderField: name) }
        // Persist BEFORE dispatch; process death/timeout/cancellation cannot unlock an uncertain POST.
        try NativeReplyProtocol.DispatchGate(defaults: defaults).begin(identity)
        do {
            let (data, response) = try await transport.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url == form.action,
                  let xml = String(data: data, encoding: .utf8) else { throw NativeReplyProtocol.ReplyError.unknown }
            let result = try NativeReplyProtocol.success(xml, base: base, tid: tid)
            NativeReplyProtocol.DispatchGate(defaults: defaults).resolved(identity)
            return result
        } catch NativeReplyProtocol.ReplyError.rejected {
            NativeReplyProtocol.DispatchGate(defaults: defaults).resolved(identity)
            throw NativeReplyProtocol.ReplyError.rejected
        } catch { throw NativeReplyProtocol.ReplyError.unknown }
    }
}
