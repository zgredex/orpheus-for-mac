import AppKit
import Foundation

/// Process-owned termination bridge. It is retained by the process-scoped view
/// model rather than a window, so closing every window cannot detach cleanup.
@MainActor
final class NativeApplicationTerminationObserver {
    private let center: NotificationCenter
    private var token: NSObjectProtocol?

    init(
        center: NotificationCenter = .default,
        notificationName: Notification.Name = NSApplication.willTerminateNotification,
        onTermination: @escaping @MainActor () -> Void
    ) {
        self.center = center
        token = center.addObserver(
            forName: notificationName,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                onTermination()
            }
        }
    }

    deinit {
        if let token { center.removeObserver(token) }
    }
}
