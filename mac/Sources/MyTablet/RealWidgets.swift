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
        guard let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg) else { return nil }
        return removingBacking(img)
    }

    /// The capture flattens macOS's widget material to black. Turning darkness into transparency
    /// keeps exactly the text and graphics macOS drew, ready to sit on real glass.
    private static func removingBacking(_ img: CGImage) -> CGImage? {
        let w = img.width, h = img.height
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let d = c.data else { return img }
        c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = d.bindMemory(to: UInt8.self, capacity: w * h * 4)
        for i in stride(from: 0, to: w * h * 4, by: 4) where px[i + 3] > 0 {
            // Keep colour as premultiplied light: the brightest channel becomes alpha.
            px[i + 3] = min(px[i + 3], max(px[i], px[i + 1], px[i + 2]))
        }
        return c.makeImage()
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
