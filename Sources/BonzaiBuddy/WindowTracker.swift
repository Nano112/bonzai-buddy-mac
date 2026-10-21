import AppKit
import CoreGraphics

struct TrackedWindow {
    let id: CGWindowID
    /// Frame in Cocoa global coordinates (bottom-left origin).
    let rect: CGRect
}

/// Reads on-screen window frames. Bounds, layer and owner are available without
/// Screen Recording permission (only window titles need it), so no prompt appears.
struct WindowTracker {
    var excludedWindowNumber: Int = 0

    /// Normal-level windows, front to back.
    func snapshot() -> [TrackedWindow] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0

        var windows: [TrackedWindow] = []
        for entry in info {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let number = entry[kCGWindowNumber as String] as? Int,
                  number != excludedWindowNumber,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0.1,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let cgRect = CGRect(dictionaryRepresentation: bounds),
                  cgRect.width >= 120, cgRect.height >= 50 else { continue }

            let rect = CGRect(x: cgRect.minX, y: primaryHeight - cgRect.maxY, width: cgRect.width, height: cgRect.height)
            windows.append(TrackedWindow(id: CGWindowID(number), rect: rect))
        }
        return windows
    }
}
