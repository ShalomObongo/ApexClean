import AppKit
import Combine

/// Answers one question: is any ApexClean window actually on screen?
///
/// Used to decide whether live sampling is worth doing at all. macOS has no
/// single notification for "the user can no longer see this app" — occlusion,
/// hiding, and miniaturising are three separate events, and hiding does not
/// post an occlusion change — so all of them are merged into one signal and
/// the answer is recomputed from scratch each time rather than tracked
/// incrementally, which would drift.
enum WindowVisibility {
    static var changes: AnyPublisher<Notification, Never> {
        let center = NotificationCenter.default
        return Publishers.MergeMany(
            center.publisher(for: NSWindow.didChangeOcclusionStateNotification),
            center.publisher(for: NSWindow.didMiniaturizeNotification),
            center.publisher(for: NSWindow.didDeminiaturizeNotification),
            center.publisher(for: NSApplication.didHideNotification),
            center.publisher(for: NSApplication.didUnhideNotification)
        )
        .eraseToAnyPublisher()
    }

    /// The menu bar extra owns its own popover window, which must not count as
    /// the main interface being visible, so only ordinary windows are asked.
    static var isAnyWindowOnScreen: Bool {
        guard let app = NSApp, !app.isHidden else { return false }
        return app.windows.contains { window in
            window.isVisible
                && !window.isMiniaturized
                && window.occlusionState.contains(.visible)
        }
    }
}
