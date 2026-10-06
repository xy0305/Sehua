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
        // Exercise the same insertion policy used by WebSession, including
        // active-navigation exclusion, FIFO, and removal of cancelled waiters.
        var waiting: [(String, Bool, Double)] = [("browse1", false, 2), ("browse2", false, 3)]
        let activeRemaining = 1.0
        let fifoWait = activeRemaining + waiting.reduce(0) { $0 + $1.2 }
        let index = PresentationTiming.insertionIndex(interactive: true, queuedInteractive: waiting.map { $0.1 })
        waiting.insert(("detail1", true, 1), at: index)
        precondition(waiting.map { $0.0 } == ["detail1", "browse1", "browse2"])
        let priorityWait = activeRemaining + waiting.prefix(index).reduce(0) { $0 + $1.2 }
        precondition(fifoWait == 6 && priorityWait == 1)
        let second = PresentationTiming.insertionIndex(interactive: true, queuedInteractive: waiting.map { $0.1 })
        waiting.insert(("detail2", true, 1), at: second)
        precondition(waiting.map { $0.0 } == ["detail1", "detail2", "browse1", "browse2"])
        precondition(PresentationTiming.insertionIndex(interactive: false, queuedInteractive: waiting.map { $0.1 }) == 4)
        waiting.removeAll { $0.0 == "detail1" }
        precondition(waiting.first?.0 == "detail2")
        precondition(PresentationTiming.insertionIndex(interactive: true, queuedInteractive: []) == 0)
        precondition(PresentationTiming.insertionIndex(interactive: true, queuedInteractive: [true, true]) == 2)
        print("Detail queue controlled production policy: FIFO wait=6s priority wait=1s saved=5s; no network/device measurement")
        print("Production presentation policy fixtures passed (controlled schedule only)")
    }
}
