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
    enum Readiness { case complete, threadBody }
    private var readiness: [UUID: Readiness] = [:]
    private var waiters: [UUID: CheckedContinuation<String, Error>] = [:]
    private var timeoutWork: [UUID: DispatchWorkItem] = [:]
    private var queue: [(url: URL, id: UUID, timeout: TimeInterval, interactive: Bool)] = []
    private var activeID: UUID?
    private var activeNavigation: WKNavigation?
    private var ageGateRequestID: UUID?
    private var collectGen = 0
    private var commitSamplerGen: Int?
    private var fetchTimings: [UUID: DetailFetchTiming] = [:]
    // Last numeric-only sample for read-only diagnostics and the production runner.
    private(set) var lastFetchSample: (timing: DetailFetchTiming, end: TimeInterval)?

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

    func fetchHTML(_ path: String, timeout: TimeInterval = 25, interactive: Bool = false, readiness policy: Readiness = .complete) async throws -> String {
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
                readiness[id] = policy
                fetchTimings[id] = DetailFetchTiming(enqueued: ProcessInfo.processInfo.systemUptime)
                // The active request remains at the front; only waiting reads
                // are reordered. No navigation, login, or write is preempted.
                let start = activeID == nil ? 0 : 1
                let waiting = queue.dropFirst(start).map { $0.interactive }
                let index = start + PresentationTiming.insertionIndex(interactive: interactive, queuedInteractive: waiting)
                queue.insert((target, id, timeout, interactive), at: index)
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
        fetchTimings[next.id]?.started = ProcessInfo.processInfo.systemUptime
        collectGen += 1
        let scripts = webView.configuration.userContentController
        scripts.removeAllUserScripts()
        if readiness[next.id] == .threadBody {
            scripts.addUserScript(WKUserScript(source: ThreadDOMReadiness.install, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
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
        readiness.removeValue(forKey: id)
        timeoutWork.removeValue(forKey: id)?.cancel()
        if let timing = fetchTimings.removeValue(forKey: id) {
            let cancelled: Bool
            if case .failure(let error) = result { cancelled = error is CancellationError } else { cancelled = false }
            let end = ProcessInfo.processInfo.systemUptime
            lastFetchSample = (timing, end)
            DetailPerformance.logFetch(timing, end: end, cancelled: cancelled)
        }
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
        commitSamplerGen = gen
        fetchTimings[id]?.committed = ProcessInfo.processInfo.systemUptime
        collectHTML(attempt: 0, id: id, gen: gen)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let id = requestID(for: navigation), id == activeID,
              navigation === activeNavigation else { return }
        // Resource completion used to discard the commit sample and impose a
        // fresh 0.4 + 0.7s window. Reuse it without weakening body stability.
        guard PresentationTiming.restartSampler(hasCommitSampler: commitSamplerGen == collectGen) else { return }
        collectGen += 1
        let gen = collectGen
        clickAgeGateIfNeeded(id: id, gen: gen)
        collectHTML(attempt: 0, id: id, gen: gen)
    }

    private func collectHTML(attempt: Int, id: UUID, gen: Int, previousBody: String? = nil) {
        let delay: TimeInterval = attempt == 0 ? 0.4 : 0.7
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.activeID == id, gen == self.collectGen else { return }
            self.fetchTimings[id]?.samples += 1
            self.webView.evaluateJavaScript(ThreadDOMReadiness.snapshot) { [weak self] result, error in
                let snapshot = result as? [String: Any]
                let html = (snapshot?["html"] as? String) ?? ""
                let documentReady = (snapshot?["ready"] as? String) == "complete"
                    && (self?.readiness[id] != .threadBody || (snapshot?["settled"] as? Bool) == true)
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
                        let signature = self.readiness[id] == .threadBody ? ((snapshot?["signature"] as? String) ?? body) : body
                        let stable = signature == previousBody
                        let safeEarly = self.readiness[id] == .threadBody
                            && (snapshot?["safe"] as? Bool) == true && !body.isEmpty && stable
                        if safeEarly {
                            self.finish(html, id: id, gen: gen)
                            return
                        }
                        // Unknown asynchronous work, loading/permission placeholders and
                        // unstable attachment/pagination DOM always retain complete fallback.
                        if (!documentReady || !stable) && attempt < 24 {
                            self.collectHTML(attempt: attempt + 1, id: id, gen: gen, previousBody: signature)
                            return
                        }
                        if documentReady || (self.readiness[id] != .threadBody && !body.isEmpty) {
                            self.finish(html, id: id, gen: gen)
                            return
                        }
                        self.complete(id: id, result: .failure(URLError(.timedOut)))
                        return
                    }
                    let ready = (documentReady && html.contains("id=\"postform\"")) || html.contains("n5_htnrbt") || html.contains("class=\"btdb\"") || html.contains("n5_bbsbk")
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

// Fail-closed document-start instrumentation: arbitrary deferred work is not
// assumed to be advertising. If it cannot be proven idle, use complete mode.
private enum ThreadDOMReadiness {
    static let install = #"""
    (() => {
      const s = window.__shtReadiness = {timers:new Set(), intervals:new Set(), io:0,
        last:performance.now(), loaded:new WeakSet(), loadHandlers:false, failed:false};
      try {
        const timeout=window.setTimeout, clear=window.clearTimeout;
        window.setTimeout=function(fn, delay, ...args) {
          let id=timeout.call(window, function(){s.timers.delete(id); s.last=performance.now();
            if(typeof fn==='function') fn.apply(window,args); else (0,eval)(fn);}, delay);
          s.timers.add(id); return id;
        };
        window.clearTimeout=function(id){s.timers.delete(id);s.intervals.delete(id);return clear.call(window,id);};
        const interval=window.setInterval, cancel=window.clearInterval;
        window.setInterval=function(...args){const id=interval.apply(window,args);s.intervals.add(id);return id;};
        window.clearInterval=function(id){s.intervals.delete(id);s.timers.delete(id);return cancel.call(window,id);};
        for(const [schedule,cancelName] of [['requestAnimationFrame','cancelAnimationFrame'],['requestIdleCallback','cancelIdleCallback']]) {
          if(!window[schedule])continue;
          const original=window[schedule], cancelOriginal=window[cancelName];
          window[schedule]=function(fn,...args){let token={};s.timers.add(token);
            const id=original.call(window,(...values)=>{s.timers.delete(token);s.last=performance.now();fn(...values);},...args);
            token.id=id;token.kind=schedule;return id;};
          window[cancelName]=function(id){for(const token of s.timers){if(token.kind===schedule && token.id===id)s.timers.delete(token);}return cancelOriginal.call(window,id);};
        }
        for(const name of ['Worker','SharedWorker','WebSocket','EventSource']) {
          if(!window[name])continue;const Original=window[name];
          window[name]=new Proxy(Original,{construct(target,args){s.failed=true;return Reflect.construct(target,args);}});
        }
        const fetch=window.fetch;
        window.fetch=function(...args){s.io++;return fetch.apply(this,args).finally(()=>{s.io--;s.last=performance.now();});};
        // Fetch resolves at headers; body consumers can still inject content later.
        for(const method of ['text','json','blob','arrayBuffer','formData']) {
          const original=Response.prototype[method];if(!original)continue;
          Response.prototype[method]=function(...args){s.io++;
            try{return original.apply(this,args).finally(()=>{s.io--;s.last=performance.now();});}
            catch(e){s.io--;throw e;}};
        }
        if(window.ReadableStreamDefaultReader){const read=ReadableStreamDefaultReader.prototype.read;
          ReadableStreamDefaultReader.prototype.read=function(...args){s.io++;
            return read.apply(this,args).finally(()=>{s.io--;s.last=performance.now();});};}
        const send=XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.send=function(...args){s.io++;
          this.addEventListener('loadend',()=>{s.io--;s.last=performance.now();},{once:true});
          try{return send.apply(this,args);}catch(e){s.io--;throw e;}};
        const add=EventTarget.prototype.addEventListener;
        EventTarget.prototype.addEventListener=function(type,...args){
          if(type==='load' || type==='error' || type==='message' || type.startsWith('animation') || type.startsWith('transition'))s.loadHandlers=true;
          return add.call(this,type,...args);
        };
        add.call(document,'load',e=>{if(e.target.tagName==='SCRIPT')s.loaded.add(e.target);},true);
        add.call(document,'error',e=>{if(e.target.tagName==='SCRIPT')s.failed=true;},true);
        new MutationObserver(()=>{s.last=performance.now();}).observe(document,{subtree:true,childList:true,attributes:true,characterData:true});
      } catch(e) {s.failed=true;}
    })();
    """#
    static let snapshot = #"""
    (() => {
      const s=window.__shtReadiness, body=document.body;
      const html=document.contentType.includes('xml') ? new XMLSerializer().serializeToString(document) : document.documentElement.outerHTML;
      // Include attachment galleries, permission/purchase evidence and page links,
      // not only message text. Resource completion does not change this signature.
      const signature=body ? body.innerHTML : '';
      const text=body ? body.innerText : '';
      const messages=[...document.querySelectorAll('.message, [id^="postmessage_"]')];
      const populated=messages.length>0 && messages.every(e=>e.textContent.trim() || e.querySelector('img,a,video'));
      const placeholder=document.querySelector('[aria-busy="true"],.loading,.loadmore.loading,.skeleton,[data-loading="true"],#messagetext,.alert_error,.locked,.pay,.showhide');
      const restricted=/请先登录|登录后|无权|权限不足|购买主题|购买后|隐藏内容|回复后|满18岁|Just a moment|验证您|正在加载|加载中/.test(text);
      const pendingScript=s && [...document.scripts].some(e=>e.src && !s.loaded.has(e));
      const unknownModule=[...document.scripts].some(e=>e.type==='module' || /\bimport\s*\(/.test(e.textContent));
      const unsafeFrame=[...document.querySelectorAll('iframe,object,embed')].some(e=>
        e.tagName!=='IFRAME' || !e.hasAttribute('sandbox') || e.sandbox.contains('allow-scripts'));
      const mediaCallback=[...document.querySelectorAll('img,iframe,link,video,audio')].some(e=>e.onload || e.onerror);
      const safe=!!(s && !s.failed && document.readyState==='interactive' && populated
        && !placeholder && !restricted && !pendingScript && !unknownModule && !unsafeFrame && !mediaCallback && !s.loadHandlers
        && !window.onload && !window.onmessage && !document.querySelector('[onload],[onerror]') && !s.io && !s.timers.size && !s.intervals.size
        && performance.now()-s.last>=900);
      const settled=!!(s && !s.failed && !s.io && !s.timers.size && !s.intervals.size && performance.now()-s.last>=900);
      return {html,ready:document.readyState,signature,safe,settled};
    })();
    """#
}
