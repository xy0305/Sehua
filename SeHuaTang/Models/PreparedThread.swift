import Foundation

/// Immutable, response-scoped presentation. No cookies, shared cache, UIKit or
/// WebKit crosses the worker boundary. HTML/DiscuzParser have no mutable statics;
/// every regex and intermediate buffer is local to the call.
struct PreparedThread: Sendable {
    let detail: ThreadDetail
    let blocks: [String: [HTML.Content]]
    let groups: [String: [[HTML.Content]]]
    static let lookAheadFragments = 3
    let inlineAttachmentIDs: Set<String>
    let nextPage: URL?
    let parseMilliseconds: Double

    static func prepare(html: String, tid: Int, base: URL, title: String, page: Int) throws -> PreparedThread {
        try Task.checkCancellation()
        let start = ProcessInfo.processInfo.systemUptime
        let detail = DiscuzParser.parseThreadDetail(html, tid: tid, base: base, fallbackTitle: title)
        var blocks: [String: [HTML.Content]] = [:]
        var inline = Set<String>()
        for post in detail.posts {
            try Task.checkCancellation()
            let content = HTML.orderedContent(in: post.htmlBody, base: base)
            blocks[post.id] = content
            for fragment in content {
                if case .attachment(let file) = fragment { inline.insert(file.url.absoluteString) }
            }
        }
        let next = DiscuzParser.nextThreadPage(in: html, tid: tid, base: base, page: page)
        try Task.checkCancellation()
        var groups: [String: [[HTML.Content]]] = [:]
        for (id, content) in blocks {
            // Lazy rows eagerly instantiate a small, ordered look-ahead window.
            // Images after the current text/image begin loading before scrolling
            // within that row; nothing is removed, reordered or source-rewritten.
            groups[id] = stride(from: 0, to: content.count, by: lookAheadFragments).map {
                Array(content[$0..<min($0 + lookAheadFragments, content.count)])
            }
        }
        return PreparedThread(detail: detail, blocks: blocks, groups: groups, inlineAttachmentIDs: inline, nextPage: next,
                              parseMilliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000)
    }

    static func load(html: String, tid: Int, base: URL, title: String, page: Int) async throws -> PreparedThread {
        let worker = Task.detached(priority: .userInitiated) {
            try prepare(html: html, tid: tid, base: base, title: title, page: page)
        }
        return try await withTaskCancellationHandler(operation: {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        }, onCancel: { worker.cancel() })
    }
}
