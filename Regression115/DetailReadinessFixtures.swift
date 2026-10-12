import Foundation
import AppKit
import WebKit

@main struct DetailReadinessFixtures {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let session = WebSession.shared
        let origin = "http://127.0.0.1:18765"
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 390,height: 844), styleMask: [.borderless],backing: .buffered,defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = session.webView
        func read(_ path: String, _ policy: WebSession.Readiness) async throws -> (String, Double) {
            let start = ProcessInfo.processInfo.systemUptime
            let html = try await session.fetchHTML(origin + path + "?mod=viewthread", readiness: policy)
            let elapsed = ProcessInfo.processInfo.systemUptime-start
            let sample = session.lastFetchSample!
            let d = sample.timing.durations(at: sample.end)
            print("CONTROLLED \(path) policy=\(policy) queue_ms=\(d.queue) navigation_ms=\(d.navigation) dom_ms=\(d.dom) total_s=\(elapsed)")
            return (html,elapsed)
        }
        let (old,oldTime) = try await read("/normal",.complete)
        let (new,newTime) = try await read("/normal",.threadBody)
        precondition(oldTime>=5 && newTime<4 && old==new, "slow unrelated resources must not gate complete body; DOM/media must remain identical")
        let (_,unsafeTime) = try await read("/unsafe-frame",.threadBody)
        precondition(unsafeTime>=5,"an unknown script-capable iframe cannot be assumed unrelated to thread injection")
        let (interval,intervalTime) = try await read("/interval-late",.threadBody)
        precondition(intervalTime>=7 && DiscuzParser.messageBodies(in:interval).joined().contains("FINAL interval body"))
        for path in ["/permanent-interval", "/permanent-worker", "/permanent-interval-late"] {
            let (html,elapsed) = try await read(path,.threadBody)
            precondition(elapsed>=8 && elapsed<15,"permanent unknown activity must use bounded complete fallback, never early delivery or timeout")
            let expected = path.hasSuffix("-late") ? "FINAL permanent activity body" : "complete body"
            precondition(DiscuzParser.messageBodies(in:html).joined().contains(expected),"complete fallback must retain delayed body")
        }
        let (streamed,streamedTime) = try await read("/streamed",.threadBody)
        precondition(streamedTime>=3 && DiscuzParser.messageBodies(in:streamed).joined().contains("FINAL streamed body"))
        let (late,lateTime) = try await read("/late",.threadBody)
        precondition(lateTime>=3 && late.contains("FINAL body") && late.contains("FINAL attachment") && late.contains("/net-image-late.gif"))
        let (empty,emptyTime) = try await read("/empty-late",.threadBody)
        precondition(emptyTime>=3 && empty.contains("FINAL body") && empty.contains("/net-image-late.gif"))
        let (permission,permissionTime) = try await read("/permission",.threadBody)
        precondition(permissionTime>=5 && permission.contains("隐藏内容需回复") && permission.contains("购买主题"))
        let (load,loadTime) = try await read("/load-late",.threadBody)
        precondition(loadTime>=7 && load.contains("FINAL load dependent body"))
        let (restricted,restrictedTime) = try await read("/restricted",.threadBody)
        precondition(restrictedTime<5 && restricted.contains("权限不足"),"restricted/no-body should return actionable HTML, not hang")
        // Same production network called by prefetch and SiteImage, real HTTP.
        let network = SiteImageNetwork.shared
        let url = URL(string:origin+"/net-image-shared.gif")!
        let prefetch = Task { try await network.data(url:url,referer:origin,visible:false) }
        try await Task.sleep(nanoseconds:100_000_000)
        let visible = Task { try await network.data(url:url,referer:origin) }
        try await Task.sleep(nanoseconds:100_000_000)
        let priority = network.diagnosticCounts
        precondition(priority.highPriority==1 && priority.active==1,"visible join must upgrade the shared download")
        prefetch.cancel()
        do { _ = try await prefetch.value; fatalError("prefetch cancellation not delivered") } catch is CancellationError {}
        let bytes = try await visible.value
        precondition(String(data:bytes,encoding:.utf8)=="GIF89a-retained-original-bytes")
        let cached = try await network.data(url:url,referer:origin)
        precondition(cached==bytes)
        let batch = (0..<6).map { index in Task { try await network.data(url:URL(string:origin+"/net-image-bound-\(index).gif")!,referer:origin,visible:false) } }
        try await Task.sleep(nanoseconds:100_000_000)
        let bounded = network.diagnosticCounts
        precondition(bounded.active==2 && bounded.speculative==2 && bounded.queued==4)
        for task in batch { _ = try await task.value }
        let reverseURL=URL(string:origin+"/net-image-reverse.gif")!
        let survivor=Task { try await network.data(url:reverseURL,referer:origin,visible:false) }
        try await Task.sleep(nanoseconds:100_000_000)
        let leaving=Task { try await network.data(url:reverseURL,referer:origin) }
        try await Task.sleep(nanoseconds:100_000_000)
        leaving.cancel()
        do { _ = try await leaving.value; fatalError("visible cancellation not delivered") } catch is CancellationError {}
        _ = try await survivor.value
        let redirected = try await network.data(url:URL(string:origin+"/redirect")!,referer:origin)
        precondition(redirected==bytes)
        let retryURL=URL(string:origin+"/net-image-retry.gif")!
        do { _ = try await network.data(url:retryURL,referer:origin); fatalError("503 must fail") } catch {}
        _ = try await network.data(url:retryURL,referer:origin)
        let cookie = HTTPCookie(properties:[.domain:"source.example",.path:"/",.name:"auth",.value:"fixture-A"])!
        let other = HTTPCookie(properties:[.domain:"source.example",.path:"/",.name:"auth",.value:"fixture-B"])!
        let keyA=SiteImageNetwork.request(url:url,referer:origin,cookies:[cookie]).1
        let keyB=SiteImageNetwork.request(url:url,referer:origin,cookies:[other]).1
        precondition(keyA != keyB,"CDN URL without matching cookie must still be account-isolated")
        let keySource=SiteImageNetwork.request(url:url,referer:origin+"/other",cookies:[cookie]).1
        precondition(keySource != keyA)
        // Real WK account snapshot: changing source-domain auth must issue a new
        // HTTP request even when no cookie matches the image's localhost domain.
        await session.webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        _ = try await network.data(url:url,referer:origin)
        await session.webView.configuration.websiteDataStore.httpCookieStore.setCookie(other)
        _ = try await network.data(url:url,referer:origin)
        let (statsData,_) = try await URLSession.shared.data(from:URL(string:origin+"/stats")!)
        let counts=try JSONDecoder().decode([String:Int].self,from:statsData)
        precondition(counts["/net-image-shared.gif"]==3,"one shared flight plus two isolated accounts")
        precondition(counts["/net-image-retry.gif"]==2,"failed flight must retry")
        print("PASS production WK readiness/default isolation/delayed DOM/permissions; image flight cancellation isolation, byte/GIF preservation, account/source keys, failure retry; shared HTTP count=1 before account changes")
        window.close()
    }
}
