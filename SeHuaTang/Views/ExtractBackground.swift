import SwiftUI
import BackgroundTasks
import UIKit

/// iOS best effort only; force quit/suspension never promises continued execution.
@MainActor enum ExtractBackground {
    static let taskID = "app.sehuatang.ios.extract"
    private static var foregroundWork: Task<Void, Never>?
    private static var backgroundWork: Task<Bool, Never>?

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: .main) { task in
            guard let processing = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in handle(processing) }
        }
    }

    static func schedule() {
        guard SHT115ExtractionPolicy.enabled() else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskID)
            return
        }
        Task { @MainActor in
            let settings = SHT115Settings.load()
            guard let service = try? Pan115UIService.get(),
                  await service.hasPendingExtraction(settings: settings) else { return }
            let request = BGProcessingTaskRequest(identifier: taskID)
            request.requiresNetworkConnectivity = true
            request.requiresExternalPower = false
            request.earliestBeginDate = Date(timeIntervalSinceNow: 300)
            try? BGTaskScheduler.shared.submit(request)
        }
    }

    /// Detached from the submit button: submit acceptance does not await this work.
    static func kick() {
        guard SHT115ExtractionPolicy.enabled(), foregroundWork == nil else { return }
        foregroundWork = Task { @MainActor in
            defer { foregroundWork = nil; BackgroundRun.end(); schedule() }
            let settings = SHT115Settings.load()
            guard let service = try? Pan115UIService.get() else { return }
            try? await service.runExtractionQueue(settings: settings)
        }
    }

    /// Call when account, parent CID, or automation setting changes.
    static func stop() {
        foregroundWork?.cancel()
        backgroundWork?.cancel()
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskID)
        BackgroundRun.end()
    }

    private static func handle(_ task: BGProcessingTask) {
        let work = Task { @MainActor in
            guard SHT115ExtractionPolicy.enabled(), let service = try? Pan115UIService.get() else { return false }
            do {
                try await service.runExtractionQueue(settings: SHT115Settings.load())
                return !Task.isCancelled
            } catch { return false }
        }
        backgroundWork?.cancel()
        backgroundWork = work
        task.expirationHandler = { work.cancel() }
        Task { @MainActor in
            let success = await work.value
            backgroundWork = nil
            task.setTaskCompleted(success: success)
            schedule()
        }
    }
}

struct BackgroundKeepAlive: View {
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: scenePhase) { phase in
                if phase == .background {
                    if SHT115ExtractionPolicy.enabled() { BackgroundRun.begin(); ExtractBackground.kick(); ExtractBackground.schedule() }
                } else if phase == .active {
                    BackgroundRun.end(); ExtractBackground.kick()
                }
            }
    }
}

@MainActor enum BackgroundRun {
    private static var id: UIBackgroundTaskIdentifier = .invalid
    static func begin() {
        guard id == .invalid else { return }
        id = UIApplication.shared.beginBackgroundTask(withName: "115-extract") { Task { @MainActor in ExtractBackground.stop() } }
    }
    static func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
