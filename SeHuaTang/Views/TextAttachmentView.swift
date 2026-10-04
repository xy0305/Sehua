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
            text = try await ResourceLinkExtractor.readTextAttachment(attachment.url, referer: session.baseURL)

        } catch is CancellationError {
        } catch {
            self.error = ResourceLinkExtractor.safeMessage(error)
        }
    }
}

private enum PreviewError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let value): return value }
    }
}
