import Foundation
#if canImport(os)
import os
#endif

/// Numeric-only instrumentation: never logs URLs, HTML, identity or cookies.
struct DetailFetchTiming {
    let enqueued: TimeInterval
    var started: TimeInterval?
    var committed: TimeInterval?
    var samples = 0
    func durations(at end: TimeInterval) -> (queue: Double, navigation: Double, dom: Double, total: Double) {
        let start = started ?? end
        let commit = committed ?? end
        return ((start - enqueued) * 1000, (commit - start) * 1000,
                (end - commit) * 1000, (end - enqueued) * 1000)
    }
}

enum DetailPerformance {
    static func logFetch(_ timing: DetailFetchTiming, end: TimeInterval, cancelled: Bool) {
        let d = timing.durations(at: end)
        #if canImport(os)
        Logger(subsystem: "SeHuaTang", category: "DetailPerformance").info("fetch queue_ms=\(d.queue, privacy: .public) navigation_ms=\(d.navigation, privacy: .public) dom_ms=\(d.dom, privacy: .public) total_ms=\(d.total, privacy: .public) samples=\(timing.samples, privacy: .public) cancelled=\(cancelled, privacy: .public)")
        #endif
    }
    static func logPreparation(milliseconds: Double) {
        #if canImport(os)
        Logger(subsystem: "SeHuaTang", category: "DetailPerformance").info("prepare_ms=\(milliseconds, privacy: .public)")
        #endif
    }
}
