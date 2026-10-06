import SwiftUI
import WebKit

struct SignVerificationView: View {
    @Binding var result: String?
    @EnvironmentObject private var session: WebSession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        SignVerificationWeb(result: $result, session: session) { dismiss() }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("签到验证码")
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SignVerificationWeb: UIViewRepresentable {
    @Binding var result: String?
    let session: WebSession
    let finish: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(result: $result, session: session, finish: finish) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = session.webView.customUserAgent
        let script = WKUserScript(source: """
        (function(){
          const original = window.fetch;
          window.fetch = async function(input, init){
            const response = await original.apply(this, arguments);
            try {
              const url = typeof input === 'string' ? input : input.url;
              if (url.indexOf('captcha&action=check') >= 0) {
                response.clone().text().then(function(text){ window.webkit.messageHandlers.signCheck.postMessage(text); });
              }
            } catch(e) {}
            return response;
          };
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        configuration.userContentController.addUserScript(script)
        configuration.userContentController.add(context.coordinator, name: "signCheck")
        webView.load(URLRequest(url: session.url("plugin.php?id=dd_sign&mobile=2")))
        return webView
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        @Binding var result: String?
        let session: WebSession
        let finish: () -> Void
        private var submitted = false
        init(result: Binding<String?>, session: WebSession, finish: @escaping () -> Void) {
            _result = result
            self.session = session
            self.finish = finish
        }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !submitted, let body = message.body as? String, NativeSignProtocol.ready(body) else { return }
            submitted = true
            Task { @MainActor in
                do {
                    let value = try await NativeSignService.shared.sign(session: session)
                    result = value
                } catch {
                    result = (error as? LocalizedError)?.errorDescription
                }
                finish()
            }
        }
    }
}

@MainActor final class NativeSignService {
    static let shared = NativeSignService()
    private var sending = false
    func sign(session: WebSession) async throws -> String {
        guard !sending else { throw NativeSignError.unknown }
        sending = true
        defer { sending = false }
        let url = session.url("plugin.php?id=dd_sign&ac=sign_v2")
        let cookies = await session.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        let transport = URLSession(configuration: configuration, delegate: PurchaseRedirectGuard(), delegateQueue: nil)
        defer { transport.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue(session.webView.customUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(session.url("plugin.php?id=dd_sign&mobile=2").absoluteString, forHTTPHeaderField: "Referer")
        let applicable = cookies.filter {
            let domain = $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            return session.baseURL.host!.lowercased() == domain || session.baseURL.host!.lowercased().hasSuffix("." + domain)
        }
        for (name, value) in HTTPCookie.requestHeaderFields(with: applicable) { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else { throw NativeSignError.unknown }
        switch NativeSignProtocol.outcome(text) {
        case .success(let message): return message
        case .failure(let error): throw error
        }
    }
}
