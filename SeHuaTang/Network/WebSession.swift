import Foundation
import WebKit
import Combine

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
    private var loading = false
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
        let target = url(path)
        return try await withCheckedThrowingContinuation { cont in
            let id = UUID()
            waiters[id] = cont
            queue.append((target, id, timeout))
            pump()
        }
    }

    private func pump() {
        guard !loading, let next = queue.first else { return }
        loading = true
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, let c = self.waiters.removeValue(forKey: next.id) else { return }
                self.webView.stopLoading()
                if self.queue.first?.id == next.id { self.queue.removeFirst() }
                self.loading = false
                c.resume(throwing: URLError(.timedOut))
                self.pump()
            }
        }
        timeoutWork[next.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + next.timeout, execute: work)
        webView.load(URLRequest(url: next.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: next.timeout))
    }

    func clickAgeGateIfNeeded() {
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
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func currentHTML() async -> String {
        (try? await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String) ?? ""
    }

    func finish(_ html: String) {
        needsChallenge = DiscuzParser.looksLikeChallenge(html)
        if let name = DiscuzParser.loggedInUsername(html) { username = name }
        resumeFirst(result: .success(html))
    }

    private func resumeFirst(result: Result<String, Error>) {
        guard !queue.isEmpty else { return }
        let id = queue.removeFirst().id
        guard let c = waiters.removeValue(forKey: id) else {
            loading = false
            pump()
            return
        }
        timeoutWork[id]?.cancel()
        timeoutWork[id] = nil
        loading = false
        switch result {
        case .success(let s): c.resume(returning: s)
        case .failure(let e): c.resume(throwing: e)
        }
        pump()
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
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        clickAgeGateIfNeeded()
        collectGen += 1
        collectHTML(attempt: 0, gen: collectGen)
    }

    private func collectHTML(attempt: Int, gen: Int) {
        let delay: TimeInterval = attempt == 0 ? 0.4 : 0.7
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, gen == self.collectGen else { return }
            self.webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
                let html = (result as? String) ?? ""
                Task { @MainActor in
                    guard let self, gen == self.collectGen else { return }
                    if DiscuzParser.looksLikeChallenge(html) {
                        self.needsChallenge = true
                        if attempt < 8 {
                            self.clickAgeGateIfNeeded()
                            self.collectHTML(attempt: attempt + 1, gen: gen)
                        } else {
                            self.finish(html)
                        }
                        return
                    }
                    let ready = html.contains("n5_htnrbt") || html.contains("class=\"btdb\"") || html.contains("n5_bbsbk")
                    if !ready && attempt < 8 {
                        self.collectHTML(attempt: attempt + 1, gen: gen)
                        return
                    }
                    self.finish(html)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        resumeFirst(result: .failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        resumeFirst(result: .failure(error))
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
