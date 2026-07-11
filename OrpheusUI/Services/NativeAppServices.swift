import AppKit
import UserNotifications

@MainActor
protocol AppNotificationDelivering: AnyObject {
    func notifyBatchFinished(completed: Int, failed: Int)
}

@MainActor
final class UserNotificationService: AppNotificationDelivering {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func notifyBatchFinished(completed: Int, failed: Int) {
        guard completed > 0 || failed > 0, !NSApplication.shared.isActive else { return }

        let content = UNMutableNotificationContent()
        content.sound = .default

        if failed == 0 {
            content.title = completed == 1 ? "Download complete" : "Downloads complete"
            content.body = completed == 1
                ? "Your Qobuz download is ready."
                : "\(completed) Qobuz downloads are ready."
        } else if completed == 0 {
            content.title = failed == 1 ? "Download failed" : "Downloads failed"
            content.body = failed == 1
                ? "A Qobuz download needs attention."
                : "\(failed) Qobuz downloads need attention."
        } else {
            content.title = "Download batch finished"
            content.body = "\(completed) completed, \(failed) failed."
        }

        Task {
            let settings = await center.notificationSettings()
            var authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            if settings.authorizationStatus == .notDetermined {
                authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) == true
            }
            guard authorized else { return }
            try? await center.add(UNNotificationRequest(
                identifier: "download-batch-\(UUID().uuidString)",
                content: content,
                trigger: nil
            ))
        }
    }
}

@MainActor
protocol DockProgressReporting: AnyObject {
    func update(progress: Double?, badge: String?)
    func clear()
}

@MainActor
final class DockProgressController: DockProgressReporting {
    private var containerView: NSView?
    private var progressIndicator: NSProgressIndicator?

    func update(progress: Double?, badge: String?) {
        let dockTile = NSApplication.shared.dockTile
        let indicator = ensureProgressIndicator(for: dockTile)

        if let progress, progress.isFinite {
            indicator.stopAnimation(nil)
            indicator.isIndeterminate = false
            indicator.doubleValue = min(max(progress, 0), 1)
        } else {
            indicator.isIndeterminate = true
            indicator.startAnimation(nil)
        }

        dockTile.badgeLabel = badge
        dockTile.display()
    }

    func clear() {
        progressIndicator?.stopAnimation(nil)
        NSApplication.shared.dockTile.contentView = nil
        NSApplication.shared.dockTile.badgeLabel = nil
        NSApplication.shared.dockTile.display()
        containerView = nil
        progressIndicator = nil
    }

    private func ensureProgressIndicator(for dockTile: NSDockTile) -> NSProgressIndicator {
        if let progressIndicator { return progressIndicator }

        let size = NSSize(width: 128, height: 128)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let icon = NSImageView(frame: container.bounds)
        icon.image = NSApplication.shared.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(icon)

        let indicator = NSProgressIndicator(frame: NSRect(x: 10, y: 8, width: 108, height: 12))
        indicator.style = .bar
        indicator.minValue = 0
        indicator.maxValue = 1
        container.addSubview(indicator)

        dockTile.contentView = container
        containerView = container
        progressIndicator = indicator
        return indicator
    }
}

enum AppPasteboard {
    @MainActor
    static func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}
