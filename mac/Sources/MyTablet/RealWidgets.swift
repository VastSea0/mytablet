import AppKit
import ScreenCaptureKit

/// The widgets the user actually has on their macOS desktop, drawn by macOS itself.
/// Each one is an ordinary window owned by Notification Center, so they can be captured live.
enum RealWidgets {
    static func windows() async -> [SCWindow] {
        guard let c = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return [] }
        return c.windows.filter {
            $0.owningApplication?.bundleIdentifier == "com.apple.notificationcenterui" && $0.windowLayer < 0 && $0.frame.width >= 100
        }
    }

    static func image(_ w: SCWindow) async -> CGImage? {
        let cfg = SCStreamConfiguration()
        cfg.width = Int(w.frame.width * 2); cfg.height = Int(w.frame.height * 2); cfg.showsCursor = false
        cfg.backgroundColor = .clear
        return try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg)
    }

    static func displayName(_ title: String) -> String {
        if title.contains("ScreenTime") { return "Screen Time" }
        return title
    }

    /// Widgets draw in another process, so a tap opens the app behind them.
    static func appPath(_ title: String) -> String? {
        let map = ["Forecast": "/System/Applications/Weather.app", "Weather": "/System/Applications/Weather.app",
                   "Up Next": "/System/Applications/Calendar.app", "Calendar": "/System/Applications/Calendar.app",
                   "Reminders": "/System/Applications/Reminders.app", "Notes": "/System/Applications/Notes.app"]
        if title.contains("ScreenTime") { return "/System/Applications/System Settings.app" }
        return map.first { title.contains($0.key) }?.value
    }
}
