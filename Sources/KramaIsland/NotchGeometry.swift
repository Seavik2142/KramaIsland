import AppKit

/// Measures the physical notch on a notched MacBook, or adapts cleanly to the real menu bar height
/// on non-notch Macs (MacBook Air M1, iMac, Mac mini, Mac Studio) and external displays.
struct NotchGeometry: Equatable {
    let screen: NSScreen

    /// Follows Settings ▸ Visibility ▸ Display (`auto` prefers the notched built-in display,
    /// `main` follows the active main display, or matches a specific display name).
    static var current: NotchGeometry {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            return NotchGeometry(screen: NSScreen.main!)
        }
        let pref = AppSettings.shared.displayPreference
        let chosen: NSScreen
        switch pref {
        case "main":
            chosen = NSScreen.main ?? screens[0]
        case "auto", "":
            chosen = screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? screens[0]
        default:
            chosen = screens.first { $0.localizedName == pref }
                ?? screens.first { $0.safeAreaInsets.top > 0 }
                ?? NSScreen.main
                ?? screens[0]
        }
        return NotchGeometry(screen: chosen)
    }

    var hasNotch: Bool { screen.safeAreaInsets.top > 0 }

    /// Real menu bar height on non-notch displays (typically 24–25 pt), or the physical notch
    /// height on notched MacBooks (32–38 pt).
    var notchHeight: CGFloat {
        if hasNotch { return screen.safeAreaInsets.top }
        let bar = screen.frame.maxY - screen.visibleFrame.maxY
        return max(24, min(36, bar > 0 ? bar : 25))
    }

    /// Physical camera cutout width on notched displays; compact Dynamic Island pill width on
    /// non-notch displays so it stays centered without covering menu-bar items.
    var notchWidth: CGFloat {
        if hasNotch, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return max(140, right.minX - left.maxX)
        }
        return 126
    }

    static func == (a: NotchGeometry, b: NotchGeometry) -> Bool {
        a.screen === b.screen && a.notchWidth == b.notchWidth && a.notchHeight == b.notchHeight
    }
}
