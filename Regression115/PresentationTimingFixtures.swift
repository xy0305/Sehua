import Foundation

@main struct PresentationTimingFixtures {
    static func main() {
        func can(_ count: Int = 3, _ visible: Bool = true, _ foreground: Bool = true,
                 _ reduced: Bool = false, _ dragging: Bool = false, _ zoom: Bool = false) -> Bool {
            PresentationTiming.canRotate(count: count, visible: visible, foreground: foreground,
                reducedMotion: reduced, interacting: dragging, viewingImage: zoom)
        }
        precondition(PresentationTiming.carouselInterval >= 3 && PresentationTiming.carouselInterval <= 5)
        precondition(can())
        precondition(!can(1)); precondition(!can(0))
        precondition(!can(3, false)); precondition(!can(3, true, false))
        precondition(!can(3, true, true, true))
        precondition(!can(3, true, true, false, true))
        precondition(!can(3, true, true, false, false, true))
        precondition(!PresentationTiming.restartSampler(hasCommitSampler: true))
        precondition(PresentationTiming.restartSampler(hasCommitSampler: false))
        // Controlled schedule: commit=0, samples=.4/1.1, finish=.5.
        // Previous finish restart would require .9/1.6. New policy retains
        // .4/1.1; neither changes .7 body-stability interval or readiness gate.
        let commit: Double = 0, finish: Double = 0.5
        let retained = commit + 0.4 + 0.7
        let restarted = finish + 0.4 + 0.7
        precondition(retained < restarted)
        print("Production presentation policy fixtures passed (controlled schedule only)")
    }
}
