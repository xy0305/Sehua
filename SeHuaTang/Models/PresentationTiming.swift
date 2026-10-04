import Foundation

/// Shared production policy, exercised by the macOS regression runner.
enum PresentationTiming {
    static let carouselInterval: TimeInterval = 4
    static func canRotate(count: Int, visible: Bool, foreground: Bool, reducedMotion: Bool, interacting: Bool, viewingImage: Bool) -> Bool {
        count > 1 && visible && foreground && !reducedMotion && !interacting && !viewingImage
    }
    // didFinish must not invalidate a commit sampler: it already compares two
    // message-only snapshots 0.7s apart and requires document.readyState=complete.
    static func restartSampler(hasCommitSampler: Bool) -> Bool { !hasCommitSampler }
}
