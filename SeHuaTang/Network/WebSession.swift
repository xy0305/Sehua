import Foundation
import WebKit
import Combine
import ObjectiveC

@MainActor
final class WebSession: NSObject, ObservableObject {
    static let shared = WebSession()

    @Published var host: String {
        didSet { UserDefaults.standard.set(host, forKey: "sht.host") }
    }
    @Published var username: String?
    @Published var needsChallenge = false
    @Published var lastError: String?

    let webView: WKWebView
    private var waiters: [UUID: CheckedContinuation<String, Error>] = [:]
    private var timeoutWork: [UUID: DispatchWorkItem] = [:]
    private var queue: [(url: URL, id: UUID, timeout: TimeInterval)] = []
    private var activeID: UUID?
    private var activeNavigation: WKNavigation?
    private var ageGateRequestID: UUID?
    private var collectGen = 0

    var baseURL: URL { URL(string: "https://\(host)")! }

    func url(_ path: String) -> URL {
        if path.hasPrefix("http") { return URL(string: path)! }
        let p = path.hasPrefix("/") ? path : "/" + path
        return URL(string: p, relativeTo: baseURL)!.absoluteURL
    }

    private override init() {
        host = UserDefaults.standard.string(forKey: "sht.host") ?? SiteConfig.defaultHost
        let conf = WKWebViewConfiguration()
        conf.websiteDataStore = .default()
        conf.defaultWebpagePreferences.allowsContentJavaScript = true
        conf.suppressesIncrementalRendering = true
        let wv = WKWebView(frame: .zero, configuration: conf)
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        self.webView = wv
        super.init()
        wv.navigationDelegate = self
        wv.uiDelegate = self
    }

    func fetchHTML(_ path: String, timeout: TimeInterval = 25) async throws -> String {
        try Task.checkCancellation()
        let target = url(path)
        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { cont in
                guard !Task.isCancelled else {
                    cont.resume(throwing: CancellationError())
                    return
                }
                waiters[id] = cont
                queue.append((target, id, timeout))
                // Deadline includes time spent waiting behind another page.
                let work = DispatchWorkItem { [weak self] in
                    Task { @MainActor in
                        self?.complete(id: id, result: .failure(URLError(.timedOut)))
                    }
                }
                timeoutWork[id] = work
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
                pump()
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.complete(id: id, result: .failure(CancellationError()))
            }
        })
    }

    private func pump() {
        guard activeID == nil, let next = queue.first else { return }
        activeID = next.id
        collectGen += 1
        guard let navigation = webView.load(URLRequest(url: next.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: next.timeout)) else {
            complete(id: next.id, result: .failure(URLError(.unknown)))
            return
        }
        activeNavigation = navigation
        tag(navigation, id: next.id)
    }

    private func tag(_ navigation: WKNavigation, id: UUID) {
        objc_setAssociatedObject(navigation, &AssociatedKeys.fetchID, id as NSUUID, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private func requestID(for navigation: WKNavigation?) -> UUID? {
        guard let navigation else { return nil }
        return (objc_getAssociatedObject(navigation, &AssociatedKeys.fetchID) as? NSUUID).map { $0 as UUID }
    }

    private func complete(id: UUID, result: Result<String, Error>) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        timeoutWork.removeValue(forKey: id)?.cancel()
        queue.removeAll { $0.id == id }
        if activeID == id {
            // Invalidate delayed collection and JS completions BEFORE starting another load.
            collectGen += 1
            activeID = nil
            activeNavigation = nil
            ageGateRequestID = nil
            webView.stopLoading()
        }
        continuation.resume(with: result)
        pump()
    }

    private func clickAgeGateIfNeeded(id: UUID, gen: Int) {
        guard activeID == id, collectGen == gen else { return }
        ageGateRequestID = id
        let js = """
        (function(){
          var a = document.querySelector('a.enter-btn');
          if (a) { a.click(); return 'clicked'; }
          var t = document.body ? document.body.innerText : '';
          if (t.indexOf('满18岁') >= 0) {
            var links = document.querySelectorAll('a');
            for (var i=0;i<links.length;i++) { if (links[i].innerText.indexOf('满18')>=0) { links[i].click(); return 'clicked'; } }
          }
          return 'ok';
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            Task { @MainActor in
                guard let self, self.activeID == id, self.collectGen == gen else { return }
                if (result as? String) != "clicked" { self.ageGateRequestID = nil }
            }
        }
    }

    func currentHTML() async -> String {
        (try? await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String) ?? ""
    }

    private func finish(_ html: String, id: UUID, gen: Int) {
        guard activeID == id, collectGen == gen else { return }
        needsChallenge = DiscuzParser.looksLikeChallenge(html)
        if let name = DiscuzParser.loggedInUsername(html) { username = name }
        complete(id: id, result: .success(html))
    }

    func refreshAccount() {
        let gen = collectGen
        webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
            let html = (result as? String) ?? ""
            Task { @MainActor in
                guard let self, self.collectGen == gen else { return }
                if let name = DiscuzParser.loggedInUsername(html) {
                    self.username = name
                }
            }
        }
    }

    func clearCookies() {
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { recs in
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: recs) {}
        }
        username = nil
    }
}

private enum AssociatedKeys {
    static var fetchID = 0
}

extension WebSession: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let id = activeID, let navigation else { return }
        if requestID(for: navigation) == id {
            activeNavigation = navigation
        } else if requestID(for: navigation) == nil {
            // Same fetch may redirect via JS or a verification interstitial.
            // Stale explicitly tagged navigations are still rejected below.
            tag(navigation, id: id)
            activeNavigation = navigation
            ageGateRequestID = nil
        } else {
            return
        }
        collectGen += 1
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let id = requestID(for: navigation), id == activeID,
              navigation === activeNavigation else { return }
        collectGen += 1
        let gen = collectGen
        clickAgeGateIfNeeded(id: id, gen: gen)
        collectHTML(attempt: 0, id: id, gen: gen)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let id = requestID(for: navigation), id == activeID,
              navigation === activeNavigation else { return }
        collectGen += 1
        let gen = collectGen
        clickAgeGateIfNeeded(id: id, gen: gen)
        collectHTML(attempt: 0, id: id, gen: gen)
    }

    private func collectHTML(attempt: Int, id: UUID, gen: Int, previousBody: String? = nil) {
        let delay: TimeInterval = attempt == 0 ? 0.4 : 0.7
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.activeID == id, gen == self.collectGen else { return }
            self.webView.evaluateJavaScript("({html: document.documentElement.outerHTML, ready: document.readyState})") { [weak self] result, error in
                let snapshot = result as? [String: Any]
                let html = (snapshot?["html"] as? String) ?? ""
                let documentReady = (snapshot?["ready"] as? String) == "complete"
                Task { @MainActor in
                    guard let self, self.activeID == id, gen == self.collectGen else { return }
                    if let error {
                        self.complete(id: id, result: .failure(error))
                        return
                    }
                    if html.isEmpty {
                        if attempt < 24 {
                            self.collectHTML(attempt: attempt + 1, id: id, gen: gen)
                        } else {
                            self.complete(id: id, result: .failure(URLError(.cannotDecodeContentData)))
                        }
                        return
                    }
                    if DiscuzParser.looksLikeChallenge(html) {
                        self.needsChallenge = true
                        if attempt < 24 {
                            self.clickAgeGateIfNeeded(id: id, gen: gen)
                            self.collectHTML(attempt: attempt + 1, id: id, gen: gen)
                        } else {
                            self.finish(html, id: id, gen: gen)
                        }
                        return
                    }
                    let target = self.queue.first(where: { $0.id == id })?.url
                    let isThread = target.map { url in
                        let query = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems ?? []
                        return query.contains { $0.name == "mod" && $0.value == "viewthread" }
                            || url.lastPathComponent.hasPrefix("thread-")
                    } ?? false
                    if isThread {
                        // A navigation label is not evidence that the thread body is ready.
                        // Compare message-only snapshots so live counters/ads cannot starve collection.
                        let body = DiscuzParser.messageBodies(in: html).joined(separator: "\n")
                        if (!documentReady || body != previousBody) && attempt < 24 {
                            self.collectHTML(attempt: attempt + 1, id: id, gen: gen, previousBody: body)
                            return
                        }
                        if !body.isEmpty || documentReady {
                            self.finish(html, id: id, gen: gen)
                            return
                        }
                    }
                    let ready = html.contains("n5_htnrbt") || html.contains("class=\"btdb\"") || html.contains("n5_bbsbk")
                        || html.contains("class=\"message\"") || html.contains("n5_htmk")
                        || html.contains("n5_hdlbmk")
                        || self.isSpacePage(html, target: target)
                    if !ready && attempt < 8 {
                        self.collectHTML(attempt: attempt + 1, id: id, gen: gen)
                        return
                    }
                    self.finish(html, id: id, gen: gen)
                }
            }
        }
    }

    private func isSpacePage(_ html: String, target: URL?) -> Bool {
        guard let target else { return false }
        let query = URLComponents(url: target, resolvingAgainstBaseURL: true)?.queryItems ?? []
        let space = query.contains { $0.name == "mod" && $0.value == "space" }
            || target.absoluteString.contains("space-uid-")
        guard space else { return false }
        let lower = html.lowercased()
        return lower.contains("uid=") || lower.contains("viewthread") || lower.contains("thread")
            || lower.contains("个人空间") || lower.contains("主题") || lower.contains("space")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let id = requestID(for: navigation), id == activeID,
              navigation === activeNavigation else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        complete(id: id, result: .failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let id = requestID(for: navigation), id == activeID,
              navigation === activeNavigation else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        complete(id: id, result: .failure(error))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if url.scheme == "magnet" || url.scheme == "ed2k" {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}
