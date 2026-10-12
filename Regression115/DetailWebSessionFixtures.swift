import Foundation
import AppKit
import WebKit

@main struct DetailWebSessionFixtures {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let session = WebSession.shared
        let origin = "http://127.0.0.1:18764"
        // A visible WebKit host is not needed; attach to an offscreen native window
        // so the production WKNavigation delegates and JS sampler run normally.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 844), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = session.webView
        // Reproduce build 70 view disappearance: invalidate UI generation but do
        // not cancel the owned read. Same production single queue, real local I/O.
        let baselineRead = Task { try await session.fetchHTML(origin + "/slow?mod=viewthread", interactive: true) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let baselineStart = ProcessInfo.processInfo.systemUptime
        let baselineFresh = try await session.fetchHTML(origin + "/baseline?mod=viewthread", interactive: true)
        let baselineElapsed = ProcessInfo.processInfo.systemUptime - baselineStart
        let baselineSample = session.lastFetchSample!
        let baselineStages = baselineSample.timing.durations(at: baselineSample.end)
        _ = try await baselineRead.value
        precondition(baselineFresh.contains("FAST complete body"))
        let active = Task { try await session.fetchHTML(origin + "/slow?mod=viewthread", interactive: true) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let queued = Task { try await session.fetchHTML(origin + "/queued?mod=viewthread", interactive: true) }
        try await Task.sleep(nanoseconds: 100_000_000)
        queued.cancel()
        do { _ = try await queued.value; fatalError("queued read survived cancellation") } catch is CancellationError {}
        let start = ProcessInfo.processInfo.systemUptime
        active.cancel()
        do { _ = try await active.value; fatalError("active read survived cancellation") } catch is CancellationError {}
        let fresh = try await session.fetchHTML(origin + "/fresh?mod=viewthread", interactive: true)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let newSample = session.lastFetchSample!
        let newStages = newSample.timing.durations(at: newSample.end)
        print("CONTROLLED stages old_queue_ms=\(baselineStages.queue) old_navigation_ms=\(baselineStages.navigation) old_dom_ms=\(baselineStages.dom) new_queue_ms=\(newStages.queue) new_navigation_ms=\(newStages.navigation) new_dom_ms=\(newStages.dom) new_samples=\(newSample.timing.samples)")
        precondition(fresh.contains("FAST complete body") && !fresh.contains("SLOW complete body"))
        precondition(elapsed < 5.5, "cancelled slow read still blocked single queue")
        // Wait beyond the cancelled navigation's delayed response, then read again:
        // stale completions cannot resolve a different request or invalidate it.
        try await Task.sleep(nanoseconds: 6_100_000_000)
        let next = try await session.fetchHTML(origin + "/next?mod=viewthread", interactive: true)
        precondition(next.contains("FAST complete body"))
        print("CONTROLLED production WKWebView queue: build70_missing_owner_cancel_to_body_s=\(baselineElapsed) new_owner_cancel_to_body_s=\(elapsed); normal .4/.7 complete+stable DOM gates unchanged")
        print("PASS actual production WebSession active/queued cancellation, next read, stale delegate/JS isolation")
        window.close()
    }
}
