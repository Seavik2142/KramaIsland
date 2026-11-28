import AppKit
import CoreGraphics

extension NSScreen {
    /// Stable hardware display identifier (`NSScreenNumber`).
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

/// Measures the physical notch on a notched MacBook, or adapts cleanly to the real menu bar height
/// on non-notch Macs (MacBook Air M1, iMac, Mac mini, Mac Studio) and external displays.
struct NotchGeometry: Equatable {
    let screen: NSScreen

    var displayID: CGDirectDisplayID { screen.displayID }

    /// Display currently containing the mouse pointer (falls back to main or first screen).
    static var activeCursorScreen: NSScreen {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return NSScreen.main! }
        let pt = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(pt) } ?? NSScreen.main ?? screens[0]
    }

    /// All displays that should host a Dynamic Island according to Settings ▸ Visibility ▸ Show island on.
    ///
    /// - `"all"` (default): every connected display gets its own independent Dynamic Island.
    /// - `"cursor"`: one Dynamic Island that automatically follows the pointer across displays.
    /// - `"auto"`: notched built-in display only.
    /// - `"main"`: primary display only.
    /// - `<localizedName>`: pinned to a specific display by name.
    static var targetScreens: [NSScreen] {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return NSScreen.main.map { [$0] } ?? [] }
        let pref = AppSettings.shared.displayPreference
        switch pref {
        case "all", "":
            return screens
        case "cursor":
            return [activeCursorScreen]
        case "main":
            return [NSScreen.main ?? screens[0]]
        case "auto":
            return [screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? screens[0]]
        default:
            if let match = screens.first(where: { $0.localizedName == pref }) {
                return [match]
            }
            return screens
        }
    }

    /// Best single screen for current pointer/window context.
    static var current: NotchGeometry {
        let targets = targetScreens
        if targets.count > 1 {
            let cursor = activeCursorScreen
            if let match = targets.first(where: { $0.displayID == cursor.displayID }) {
                return NotchGeometry(screen: match)
            }
        }
        return NotchGeometry(screen: targets.first ?? activeCursorScreen)
    }

    var hasNotch: Bool { screen.safeAreaInsets.top > 0 }

    /// Real menu bar height on non-notch displays (typically 28–30 pt), or the physical notch
    /// height on notched MacBooks (32–38 pt).
    var notchHeight: CGFloat {
        if hasNotch { return screen.safeAreaInsets.top }
        let bar = screen.frame.maxY - screen.visibleFrame.maxY
        return max(26, min(36, bar > 0 ? bar : 28))
    }

    /// Physical camera cutout width on notched displays; sleek Dynamic Island pill width on
    /// non-notch and external displays so it stays centered without covering menu-bar items.
    var notchWidth: CGFloat {
        if hasNotch, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return max(140, right.minX - left.maxX)
        }
        return 126
    }

    static func == (a: NotchGeometry, b: NotchGeometry) -> Bool {
        a.displayID == b.displayID
            && a.screen.frame == b.screen.frame
            && a.notchWidth == b.notchWidth
            && a.notchHeight == b.notchHeight
    }
}
