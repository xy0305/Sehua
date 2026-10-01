import SwiftUI
import WebKit
import CoreFoundation

/// Text attachments are read in memory using the forum's existing login cookies.
struct TextAttachmentView: View {
    let attachment: ThreadAttachment
    @EnvironmentObject var session: WebSession
    @State private var text: String?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        Group {
            if let text {
                ScrollView {
                    Text(text)
                        .font(.system(size: 15))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            } else if let error {
                ContentUnavailableView {
                    Label("无法预览", systemImage: "doc.text")
                } description: { Text(error) } actions: {
                    Button("重试") { Task { await load() } }
                }
            } else {
                ProgressView("正在读取文档…")
            }
        }
        .navigationTitle(attachment.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .background(ForumChrome.bar)
        .task { await load() }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let cookies = await withCheckedContinuation { continuation in
                WKWebsiteDataStore.default().httpCookieStore.getAllCookies {
                    continuation.resume(returning: $0)
                }
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 25
            configuration.timeoutIntervalForResource = 30
            let storage = configuration.httpCookieStorage
            for cookie in cookies { storage?.setCookie(cookie) }
            let client = URLSession(configuration: configuration)
            defer { client.invalidateAndCancel() }
            var request = URLRequest(url: attachment.url)
            request.setValue(session.baseURL.absoluteString + "/", forHTTPHeaderField: "Referer")
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
            let (bytes, response) = try await client.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw PreviewError.message("附件请求失败，请确认登录及下载权限。")
            }
            var data = Data()
            for try await byte in bytes {
                if data.count >= 4 * 1024 * 1024 {
                    throw PreviewError.message("文档超过 4 MB，当前内置文本预览不支持。")
                }
                data.append(byte)
            }
            try Task.checkCancellation()
            let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            let decoded: String?
            if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
                decoded = String(data: data, encoding: .utf16)
            } else {
                decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: gb18030)
            }
            guard let decoded else { throw PreviewError.message("无法识别文档编码。") }
            let start = decoded.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512).lowercased()
            if response.mimeType?.lowercased().contains("html") == true || start.contains("<!doctype html") || start.contains("<html") {
                throw PreviewError.message("站点返回了验证或权限页面，而不是 TXT。请在「我的」完成登录验证后重试。")
            }
            text = decoded
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private enum PreviewError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let value): return value }
    }
}
