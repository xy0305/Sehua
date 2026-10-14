import Foundation

@main struct DetailScrollFixtures {
    @MainActor static func main() async throws {
        let base = URL(string: "http://127.0.0.1:18766/forum.php?mod=viewthread&tid=79&page=1")!
        let layout = DetailImageLayout()
        let urls = (0..<18).map { URL(string: "/media/\($0).gif", relativeTo: base)!.absoluteURL }
        let body = urls.enumerated().map { "<p>SCROLL ROW \($0.offset)</p><img src='\($0.element.absoluteString)'>" }.joined()
        let html = "<h1 id='thread_subject'>SCROLL TOP</h1><div id='post_79'><div class='message'>\(body)</div></div><a href='forum.php?mod=viewthread&amp;tid=79&amp;page=2'>下一页</a>"
        let prepared = try await PreparedThread.load(html: html, tid: 79, base: base, title: "", page: 1)
        precondition(prepared.firstScreenImages == Array(urls.prefix(3)))
        let fragments = prepared.groups.values.flatMap { $0.flatMap { $0 } }
        let images = fragments.compactMap { item -> URL? in if case .image(let url) = item { return url }; return nil }
        precondition(images == urls, "all images and GIFs must remain ordered")
        precondition(HTML.queryInt("page", in: prepared.nextPage!.absoluteString) == 2)
        for (index, url) in urls.enumerated() {
            let key = DetailImageLayout.key(url: url, referer: base.absoluteString)
            precondition(layout.ratio(for: key) == 1)
            let width = 300.0, height = Double(600 + index * 60)
            layout.record(width: width, height: height, for: key)
            let displayedHeight = 360 / layout.ratio(for: key)
            for _ in 0..<40 {
                // Exact operations available to a cancelled/recreated lazy row:
                // no decoded bitmap, then invalid/changed re-decodes. Neither
                // operation can replace a displayed document's geometry.
                layout.record(width: 0, height: 0, for: key)
                layout.record(width: .nan, height: .infinity, for: key)
                layout.record(width: 768, height: 768, for: key)
                precondition(abs(360 / layout.ratio(for: key) - displayedHeight) < 0.001)
            }
        }
        let otherSource = DetailImageLayout.key(url: urls[0], referer: "different response")
        precondition(layout.ratio(for: otherSource) == 1)
        precondition(DetailImageLayout().ratio(for: otherSource) == 1)
        // The old production disappear branch switched every decoded image to
        // a 120pt placeholder. This reconstructs that measurable extent loss.
        let key = DetailImageLayout.key(url: urls[0], referer: base.absoluteString)
        print("OLD lifecycle extent: 720 -> 120 -> 720 pt; NEW: \(360 / layout.ratio(for: key)) -> \(360 / layout.ratio(for: key)) -> \(360 / layout.ratio(for: key)) pt")
        var gate = ThreadRequestGate()
        let token = gate.begin(tid: 79, source: base)!
        precondition(gate.begin(tid: 79, source: base) == nil)
        gate.invalidate()
        precondition(!gate.accepts(token, tid: 79, source: base))
        let retry = gate.begin(tid: 79, source: base)!
        gate.finish(token)
        precondition(gate.accepts(retry, tid: 79, source: base))
        gate.finish(retry)
        print("PASS: production document geometry, 18 ordered GIFs, three-image warmup, pagination token dedup/cancellation")
    }
}
