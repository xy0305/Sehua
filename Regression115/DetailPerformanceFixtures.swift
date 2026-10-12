import Foundation

@main struct DetailPerformanceFixtures {
    static func main() async throws {
        let base = URL(string: "https://example.test/forum.php?mod=viewthread&tid=42&mobile=2")!
        let body = (0..<24).map { "<p>正文 \($0) <a href='thread-43-1-1.html'>原生链接</a></p><img src='/\($0).gif'>" }.joined()
        let html = "<h1 id='thread_subject'>性能样本</h1>" + (0..<8).map { "<div id='post_\($0)'><div class='message'>\(body)</div></div>" }.joined()
        let oldStart = ProcessInfo.processInfo.systemUptime
        let old = BaselineDiscuzParser.parseThreadDetail(html, tid: 42, base: base)
        let oldParseMS = (ProcessInfo.processInfo.systemUptime - oldStart) * 1000
        let prepared = try await PreparedThread.load(html: html, tid: 42, base: base, title: "", page: 1)
        precondition(!old.posts.isEmpty && prepared.detail.posts == old.posts)
        precondition(prepared.firstScreenImages.map(\.lastPathComponent) == ["0.gif", "1.gif", "2.gif"])
        for post in prepared.detail.posts {
            precondition((prepared.blocks[post.id] ?? []).compactMap { fragment -> URL? in
                if case .image(let url) = fragment { return url }; return nil
            }.count == 24, "bounded warm-up must not truncate retained GIF document images")
        }
        try await withThrowingTaskGroup(of: PreparedThread.self) { group in
            for _ in 0..<8 {
                group.addTask { try await PreparedThread.load(html: html, tid: 42, base: base, title: "", page: 1) }
            }
            for try await value in group {
                precondition(value.detail.posts == prepared.detail.posts && value.blocks == prepared.blocks)
            }
        }
        for post in old.posts {
            precondition(prepared.blocks[post.id] == HTML.orderedContent(in: post.htmlBody, base: base))
            let groups = prepared.groups[post.id] ?? []
            precondition(groups.flatMap { $0 } == prepared.blocks[post.id])
            precondition(groups.allSatisfy { !$0.isEmpty && $0.count <= PreparedThread.lookAheadFragments })
        }
        // Production value types must meet checked Sendable, not unchecked escapes.
        func sendable<T: Sendable>(_ value: T) {}
        sendable(prepared)
        let cancelled = Task { () throws -> PreparedThread in
            try Task.checkCancellation()
            return try await PreparedThread.load(html: html, tid: 42, base: base, title: "", page: 1)
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("cancelled preparation committed") }
        catch is CancellationError {}
        var gate = ThreadRequestGate()
        let first = gate.begin(tid: 42, source: base)!
        gate.invalidate()
        let second = gate.begin(tid: 43, source: base)!
        gate.finish(first)
        precondition(!gate.accepts(first, tid: 42, source: base))
        precondition(gate.accepts(second, tid: 43, source: base))
        let hidden = try PreparedThread.prepare(html: "<div class='message'><div class='locked'>隐藏内容需回复</div></div>", tid: 42, base: base, title: "", page: 1)
        precondition(hidden.detail.purchaseState == .unknown)
        precondition(hidden.detail.posts.first?.plainText.contains("需回复") == true)
        let empty = try PreparedThread.prepare(html: "<div>导航不是正文</div>", tid: 42, base: base, title: "", page: 1)
        precondition(empty.detail.posts.isEmpty)
        // Wall-clock samples: same production HTML functions, no simulated CPU claims.
        var checksum = 0
        for sample in 1...3 {
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<5 { for post in old.posts { checksum += BaselineHTML.orderedContent(in: post.htmlBody, base: base).count; checksum += BaselineHTML.attachmentMarkup(in: post.htmlBody, base: base).files.count } }
            let baseline = (ProcessInfo.processInfo.systemUptime - start) * 1000
            let cachedStart = ProcessInfo.processInfo.systemUptime
            for _ in 0..<5 { for post in old.posts { checksum += prepared.blocks[post.id]?.count ?? 0 }; checksum += prepared.inlineAttachmentIDs.count }
            let cached = (ProcessInfo.processInfo.systemUptime - cachedStart) * 1000
            print("CONTROLLED sample=\(sample) html_bytes=\(html.utf8.count) posts=\(old.posts.count) redraws=5 old_render_parse_ms=\(baseline) new_snapshot_lookup_ms=\(cached) old_parse_only_ms=\(oldParseMS) new_prepare_including_blocks_ms=\(prepared.parseMilliseconds)")
        }
        var timing = DetailFetchTiming(enqueued: 0)
        timing.started = 2; timing.committed = 3; timing.samples = 2
        let d = timing.durations(at: 4.1)
        precondition(abs(d.queue - 2000) < 0.01 && abs(d.navigation - 1000) < 0.01 && abs(d.dom - 1100) < 0.01)
        print("PASS detail checked Sendable, exact content/order, hidden/empty safety, cancelled preparation, stale-source isolation, numeric stage timing; checksum=\(checksum)")
    }
}
