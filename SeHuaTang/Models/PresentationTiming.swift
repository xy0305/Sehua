import Foundation

/// Shared production policy, exercised by the macOS regression runner.
enum PresentationTiming {
    static let carouselInterval: TimeInterval = 4
    static func canRotate(count: Int, visible: Bool, foreground: Bool, reducedMotion: Bool, interacting: Bool, viewingImage: Bool) -> Bool {
        count > 1 && visible && foreground && !reducedMotion && !interacting && !viewingImage
    }
    // didFinish must not invalidate a commit sampler: it already compares two
    // message-only snapshots 0.7s apart and requires document.readyState=complete.
    /// Interactive reads may pass queued browsing reads, never interrupt an active
    /// navigation (which may be handling login, CF, or a native reply form).
    static func insertionIndex(interactive: Bool, queuedInteractive: [Bool]) -> Int {
        interactive ? (queuedInteractive.firstIndex(of: false) ?? queuedInteractive.count) : queuedInteractive.count
    }
    static func restartSampler(hasCommitSampler: Bool) -> Bool { !hasCommitSampler }
}
