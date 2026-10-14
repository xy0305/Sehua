import Foundation

/// Single foreground lane. Kicks wake a timer, never cancel an in-flight write.
/// The queue itself owns the per-item/24h budget; this driver also has a wall limit.
@MainActor public final class SHT115ExtractionDriver {
    private var worker: Task<Void, Never>?
    private var sleeper: Task<Void, Error>?
    private var activePass: Task<Void, Never>?
    private var revision = 0
    private var generation = 0
    public init() {}

    public func kick(eligible: @escaping @MainActor () -> Bool,
                     next: @escaping @MainActor () async -> Date?,
                     run: @escaping @MainActor () async -> Void,
                     budget: TimeInterval = 86_400) {
        revision += 1
        sleeper?.cancel()
        guard worker == nil else { return }
        generation += 1
        let token = generation
        worker = Task { @MainActor in
            let deadline = Date().addingTimeInterval(budget)
            defer {
                if generation == token { worker = nil; sleeper = nil }
            }
            while !Task.isCancelled && eligible() && Date() < deadline {
                let observed = revision
                let nextDue = await next()
                guard generation == token, !Task.isCancelled && eligible() else { return }
                if revision != observed { continue }
                guard let due = nextDue else { return }
                let ran = due <= Date()
                if ran {
                    let pass = Task { await run() }
                    activePass = pass
                    let timeout = Task {
                        do { try await Task.sleep(nanoseconds: 90_000_000_000) }
                        catch { return }
                        pass.cancel()
                    }
                    await pass.value
                    timeout.cancel()
                    guard generation == token else { return }
                    activePass = nil
                    // Minimum pause even on errors, an already-running BG lane, or stale due dates.
                }
                if revision != observed { continue } // accepted new queue while old pass ran
                let upcoming = await next()
                guard generation == token, !Task.isCancelled && eligible() else { return }
                if revision != observed { continue }
                guard let upcoming else { return }
                let delay = min(30, max(ran ? 20 : 1, upcoming.timeIntervalSinceNow))
                let timer = Task { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                sleeper = timer
                // stop() cancels both tasks; kick() only cancels this timer.
                _ = try? await timer.value
                guard generation == token else { return }
                sleeper = nil
            }
        }
    }

    public func stop() {
        generation += 1
        worker?.cancel(); sleeper?.cancel(); activePass?.cancel()
        worker = nil; sleeper = nil; activePass = nil
    }
}
