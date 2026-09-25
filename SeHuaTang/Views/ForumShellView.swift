import SwiftUI
import WebKit
import UIKit

/// 打开即是论坛手机版，布局跟网页一致。
/// 油猴搜索条是 fixed 贴顶，会盖住分类，这里给页面留出同样高度。
struct ForumShellView: View {
    @EnvironmentObject var session: WebSession
    @State private var webView: WKWebView?

    var body: some View {
        ForumWK(startURL: session.url("forum.php?forumlist=1&mobile=2")) { wv in
            webView = wv
        }
        .ignoresSafeArea(edges: .bottom)
        .background(Color(red: 0.957, green: 0.965, blue: 0.980))
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct ForumWK: UIViewRepresentable {
    let startURL: URL
    var onReady: (WKWebView) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let conf = WKWebViewConfiguration()
        conf.websiteDataStore = .default()
        conf.defaultWebpagePreferences.allowsContentJavaScript = true
        let uc = WKUserContentController()
        uc.addUserScript(WKUserScript(
            source: ForumPageStyle.script,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        conf.userContentController = uc
        let wv = WKWebView(frame: .zero, configuration: conf)
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        wv.navigationDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.isOpaque = false
        wv.backgroundColor = UIColor(red: 0.957, green: 0.965, blue: 0.980, alpha: 1)
        wv.load(URLRequest(url: startURL))
        onReady(wv)
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript(ForumPageStyle.script, completionHandler: nil)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if url.scheme == "magnet" || url.scheme == "ed2k" {
                decisionHandler(.cancel)
                UIApplication.shared.open(url)
                return
            }
            decisionHandler(.allow)
        }
    }
}

enum ForumPageStyle {
    /// 跟油猴美化同一套视觉，并修掉搜索条盖住板块。
    static let script = """
    (function(){
      if (window.__shtForumStyle) return;
      window.__shtForumStyle = 1;
      var css = `
        :root {
          --bg: #f4f6fa;
          --card: #ffffff;
          --primary: #5b7c99;
          --primary-soft: #e8eef4;
          --text: #2a3442;
          --text-sub: #8a97a8;
          --border: #e6ebf1;
          --search-h: 56px;
          --tab-h: 56px;
        }
        html, body.bg {
          background: var(--bg) !important;
          font-family: -apple-system, "PingFang SC", "Helvetica Neue", sans-serif !important;
        }
        body.bg {
          padding-bottom: calc(var(--tab-h) + env(safe-area-inset-bottom, 0px)) !important;
          box-sizing: border-box !important;
        }
        body.sht-search-pad {
          padding-top: var(--search-h) !important;
        }
        .show-text, .show-text3, .n5_htmk.AlookElementHide, #links,
        .n5_htmk:has(#links), a[href*="stv825"], a[href*=".cc"],
        a[href*=".vip"], a[href*="moulur"], a[href*=":4466"],
        a[href*=":5088"], a[href*=":23003"] {
          display: none !important;
        }
        #tm115_float_search {
          position: fixed !important;
          top: 0 !important;
          left: 0 !important;
          right: 0 !important;
          width: 100% !important;
          height: auto !important;
          min-height: 52px !important;
          z-index: 400 !important;
          background: var(--card) !important;
          border-bottom: 1px solid var(--border) !important;
          padding: 8px 16px !important;
          box-sizing: border-box !important;
          display: flex !important;
          align-items: center !important;
          pointer-events: none !important;
        }
        #tm115_float_search .search-wrap { pointer-events: auto !important; width: 100% !important; max-width: 100% !important; }
        .n5_tbys, .n5_tbxj { display: none !important; }
        .n5_bbszt { margin-top: 0 !important; padding-top: 0 !important; }
        .n5_bbsfq, .n5_ztflsx {
          position: relative !important;
          z-index: 1 !important;
          background: var(--card) !important;
        }
        .footer_menu, #n5_fbhfcd {
          z-index: 300 !important;
        }
      `;
      var style = document.getElementById('sht-forum-style');
      if (!style) {
        style = document.createElement('style');
        style.id = 'sht-forum-style';
        document.documentElement.appendChild(style);
      }
      style.textContent = css;
      function fitSearch() {
        var bar = document.getElementById('tm115_float_search');
        var h = 0;
        if (bar) {
          var r = bar.getBoundingClientRect();
          h = Math.ceil(r.height || bar.offsetHeight || 56);
        }
        document.documentElement.style.setProperty('--search-h', (h || 56) + 'px');
        if (document.body) document.body.classList.toggle('sht-search-pad', h > 0);
      }
      fitSearch();
      new MutationObserver(fitSearch).observe(document.documentElement, { childList: true, subtree: true });
      window.addEventListener('resize', fitSearch);
    })();
    """
}
