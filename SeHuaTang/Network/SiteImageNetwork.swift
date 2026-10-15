import Foundation
import CryptoKit
import WebKit

/// A single production transport for both visible media and bounded warm-up.
/// No URLCache/shared cookie jar: authorization is exclusively the WK snapshot.
@MainActor final class SiteImageNetwork {
    static let shared = SiteImageNetwork()
    private final class Flight {
        let request: URLRequest
        let cookies: [HTTPCookie]
        var clients: [UUID: CheckedContinuation<Data, Error>] = [:]
        var visible = Set<UUID>()
        var task: URLSessionDataTask?
        init(_ request: URLRequest, cookies: [HTTPCookie]) { self.request = request; self.cookies = cookies }
    }
    private let cache = NSCache<NSString, NSData>()
    private var flights: [String: Flight] = [:]
    private var order: [String] = []
    private let session: URLSession
    private var active = 0
    var diagnosticCounts: (active: Int, speculative: Int, queued: Int, highPriority: Int) {
        (active, flights.values.filter { $0.task != nil && $0.visible.isEmpty }.count,
         flights.values.filter { $0.task == nil }.count,
         flights.values.filter { ($0.task?.priority ?? 0) == URLSessionTask.highPriority }.count)
    }
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: config)
        cache.totalCostLimit = 24 * 1024 * 1024
        cache.countLimit = 12
    }

    func data(url: URL, referer: String, visible: Bool = true) async throws -> Data {
        try Task.checkCancellation()
        let cookies = await WebSession.shared.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        try Task.checkCancellation()
        let (request, key) = Self.request(url: url, referer: referer, cookies: cookies)
        if let value = cache.object(forKey: key as NSString) { return value as Data }
        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                let flight = flights[key] ?? Flight(request, cookies: cookies)
                if flights[key] == nil { flights[key] = flight; order.append(key) }
                flight.clients[id] = continuation
                if visible { flight.visible.insert(id); flight.task?.priority = URLSessionTask.highPriority }
                pump()
            }
        }, onCancel: { Task { @MainActor in self.cancel(key: key, id: id) } })
    }

    nonisolated static func request(url: URL, referer: String, cookies: [HTTPCookie]) -> (URLRequest, String) {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.httpShouldHandleCookies = false
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        req.setValue(referer, forHTTPHeaderField: "Referer")
        req.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let matching = cookies.filter { SiteRoutePolicy.cookieApplies($0, to: url) }.sorted { $0.path.count > $1.path.count }
        for (key, value) in HTTPCookie.requestHeaderFields(with: matching) { req.setValue(value, forHTTPHeaderField: key) }
        // Include the ENTIRE account jar, even when authorization is on a source
        // domain and the image itself is served by another CDN domain.
        let scope = cookies.map { "\($0.domain)|\($0.path)|\($0.name)|\($0.value)" }.sorted().joined(separator: "\n")
        let headers = (req.allHTTPHeaderFields ?? [:]).map { "\($0.key.lowercased()):\($0.value)" }.sorted().joined(separator: "\n")
        let hash = SHA256.hash(data: Data((url.absoluteString + "\n" + headers + "\n" + scope).utf8))
        return (req, hash.map { String(format: "%02x", $0) }.joined())
    }

    private func pump() {
        while active < 4 {
            let queued = order.filter { flights[$0]?.task == nil }
            guard let key = queued.first(where: { !(flights[$0]?.visible.isEmpty ?? true) }) ?? queued.first,
                  let flight = flights[key] else { return }
            // At most two speculative downloads; leave capacity for visible rows.
            if flight.visible.isEmpty && flights.values.filter({ $0.task != nil && $0.visible.isEmpty }).count >= 2 { return }
            let task = session.dataTask(with: flight.request) { data, response, error in
                Task { @MainActor in
                    guard self.flights[key] === flight else { return }
                    let result: Result<Data, Error>
                    if let error { result = .failure(error) }
                    else if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data, !data.isEmpty {
                        result = .success(data)
                        if data.count <= 8 * 1024 * 1024 { self.cache.setObject(data as NSData, forKey: key as NSString, cost: data.count) }
                    } else { result = .failure(URLError(.badServerResponse)) }
                    self.flights.removeValue(forKey: key)
                    self.order.removeAll { $0 == key }
                    self.active -= 1
                    for client in flight.clients.values { client.resume(with: result) }
                    self.pump()
                }
            }
            task.delegate = SiteImageRedirectGuard(cookies: flight.cookies)
            flight.task = task
            task.priority = flight.visible.isEmpty ? URLSessionTask.defaultPriority : URLSessionTask.highPriority
            active += 1
            task.resume()
        }
    }
    private func cancel(key: String, id: UUID) {
        guard let flight = flights[key], let client = flight.clients.removeValue(forKey: id) else { return }
        flight.visible.remove(id)
        if flight.visible.isEmpty { flight.task?.priority = URLSessionTask.defaultPriority }
        client.resume(throwing: CancellationError())
        // A speculative owner's departure MUST NOT kill a visible consumer.
        if flight.clients.isEmpty {
            if let task = flight.task { task.cancel(); active -= 1 }
            flights.removeValue(forKey: key)
            order.removeAll { $0 == key }
            pump()
        }
    }
}

private final class SiteImageRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let cookies: [HTTPCookie]
    init(cookies: [HTTPCookie]) { self.cookies = cookies }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let target = request.url,
              target.scheme == "https" || response.url?.scheme == "http" else { completionHandler(nil); return }
        let source = task.originalRequest?.value(forHTTPHeaderField: "Referer") ?? ""
        // Re-match domain/path/secure cookies on EVERY redirect. Never forward
        // another origin's Cookie header, or read a newer account's cookie jar.
        let next = SiteImageNetwork.request(url: target, referer: source, cookies: cookies).0
        completionHandler(next)
    }
}
