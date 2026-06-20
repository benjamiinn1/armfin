import WatchKit
import os

private let appLog = Logger(subsystem: "com.armfin", category: "AppDelegate")

final class ArmfinAppDelegate: NSObject, WKApplicationDelegate {

    func applicationDidFinishLaunching() {
        appLog.notice("applicationDidFinishLaunching — attaching background sessions")
        BetaDownloadManager.shared.attachIfNeeded()
        appLog.notice("applicationDidFinishLaunching — done")
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        appLog.notice("handle backgroundTasks — count: \(backgroundTasks.count)")
        for task in backgroundTasks {
            switch task {
            case let urlSessionTask as WKURLSessionRefreshBackgroundTask:
                let id = urlSessionTask.sessionIdentifier
                appLog.notice("Reattaching session: \(id)")
                handleURLSessionTask(id: id)
                urlSessionTask.setTaskCompletedWithSnapshot(false)
            default:
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }

    private func handleURLSessionTask(id: String) {
        if id == BetaDownloadManager.sessionIdentifier {
            BetaDownloadManager.shared.reattach(sessionIdentifier: id)
        }
    }
}
