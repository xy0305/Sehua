import SwiftUI
import BackgroundTasks
import UIKit

/// Asks iOS for extra time and a processing task so cloud extraction can continue
/// after the app leaves the foreground. The system may still suspend or kill it.
enum ExtractBackground {
    static let taskID = "app.sehuatang.ios.extract"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let processing = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            handle(processing)
        }
    }

    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: taskID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGProcessingTask) {
        schedule()
        let work = Task { @MainActor in
            let settings = SHT115Settings.load()
            guard (try? settings.validate()) != nil, let service = try? Pan115UIService.get() else { return }
            let records = await service.resources()
            for resource in records.prefix(8) {
                guard let listing = try? await service.listVideos(resourceID: resource.id, settings: settings, background: true),
                      !listing.truncated else { continue }
                for archive in listing.archives.prefix(4) {
                    _ = try? await service.requestExtraction(archive: archive, resourceID: resource.id, settings: settings, confirmed: true, background: true)
                }
            }
        }
        task.expirationHandler = { work.cancel() }
        Task {
            _ = await work.result
            task.setTaskCompleted(success: true)
        }
    }
}

struct BackgroundKeepAlive: View {
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: scenePhase) { phase in
                if phase != .active { ExtractBackground.schedule(); BackgroundRun.begin() }
                else { BackgroundRun.end() }
            }
    }
}

enum BackgroundRun {
    private static var id: UIBackgroundTaskIdentifier = .invalid
    static func begin() {
        guard id == .invalid else { return }
        id = UIApplication.shared.beginBackgroundTask(withName: "115-extract") { end() }
    }
    static func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
