import SwiftUI
import WebKit
import UIKit

/// 直接显示论坛手机版。登录、发帖、回复、图片、翻页都走站点自己的页面。
struct ForumBrowserView: View {
    @EnvironmentObject var session: WebSession
    @State private var pageTitle = "色花堂"
    @State private var canBack = false
    @State private var progress: Double = 0
    @State private var loading = false

    var body: some View {
        VStack(spacing: 0) {
            bar
            ZStack(alignment: .top) {
                ForumWK(pageTitle: $pageTitle, canBack: $canBack, progress: $progress, loading: $loading)
                if loading {
                    ProgressView(value: max(progress, 0.08))
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .frame(height: 2)
                }
            }
        }
        .background(ForumChrome.bar)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var bar: some View {
        HStack(spacing: 0) {
            Button {
                session.webView.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .disabled(!canBack)
            .opacity(canBack ? 1 : 0.35)

            Text(pageTitle)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)

            Button {
                session.webView.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            NavigationLink {
                MineView()
            } label: {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44)
            }
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .frame(height: 48)
        .background(ForumChrome.bar)
    }
}

private struct ForumWK: UIViewRepresentable {
    @Binding var pageTitle: String
    @Binding var canBack: Bool
    @Binding var progress: Double
    @Binding var loading: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(pageTitle: $pageTitle, canBack: $canBack, progress: $progress, loading: $loading)
    }

    func makeUIView(context: Context) -> WKWebView {
        let wv = WebSession.shared.webView
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.observe(wv)
        if wv.url == nil {
            wv.load(URLRequest(url: WebSession.shared.url("forum.php?forumlist=1&mobile=2")))
        }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        @Binding var pageTitle: String
        @Binding var canBack: Bool
        @Binding var progress: Double
        @Binding var loading: Bool
        private var observations: [NSKeyValueObservation] = []

        init(pageTitle: Binding<String>, canBack: Binding<Bool>, progress: Binding<Double>, loading: Binding<Bool>) {
            _pageTitle = pageTitle
            _canBack = canBack
            _progress = progress
            _loading = loading
        }

        func observe(_ webView: WKWebView) {
            observations = [
                webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
                    let title = (wv.title ?? "").components(separatedBy: " - ").first ?? ""
                    let cleaned = title.trimmingCharacters(in: .whitespaces)
                    Task { @MainActor in self?.pageTitle = cleaned.isEmpty ? "色花堂" : cleaned }
                },
                webView.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
                    Task { @MainActor in self?.canBack = wv.canGoBack }
                },
                webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                    Task { @MainActor in self?.progress = wv.estimatedProgress }
                },
                webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
                    Task { @MainActor in self?.loading = wv.isLoading }
                }
            ]
        }

        func stop() { observations.removeAll() }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            WebSession.shared.clickAgeGateIfNeeded()
            Task { @MainActor in WebSession.shared.refreshAccount() }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == "magnet" || scheme == "ed2k" || scheme == "thunder" {
                decisionHandler(.cancel)
                UIApplication.shared.open(url)
                return
            }
            if navigationAction.targetFrame == nil, scheme == "http" || scheme == "https" {
                if SiteLinks.staysInApp(url) {
                    decisionHandler(.cancel)
                    webView.load(URLRequest(url: url))
                } else {
                    decisionHandler(.cancel)
                    UIApplication.shared.open(url)
                }
                return
            }
            if scheme == "http" || scheme == "https", !SiteLinks.staysInApp(url) {
                decisionHandler(.cancel)
                UIApplication.shared.open(url)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                if SiteLinks.staysInApp(url) {
                    webView.load(URLRequest(url: url))
                } else {
                    UIApplication.shared.open(url)
                }
            }
            return nil
        }
    }
}
