import CoreGraphics

/// What the island is showing.
/// Precedence: launcher > shade > banner > expanded (hover / drag) > volume > activity > compact > collapsed.
enum IslandMode: Equatable {
    case collapsed   // matches the physical notch (or compact idle pill on non-notch screens)
    case compact     // notch + sleek balanced ears (or full compact Dynamic Island pill on non-notch screens)
    case volume      // dedicated flagship interactive volume HUD (replaces native macOS volume OSD)
    case activity    // a short live-activity HUD: charger, download, AirPods, timer done…
    case banner      // a notification dropped in
    case expanded    // hover: status, timer, next event, media card
    case shade       // click: iOS/Android-style media + notification shade
    case launcher    // hotkey: Spotlight-style search
}

/// Pure description of the island's shape, shared by the SwiftUI view and the NSPanel.
///
/// Everything is one black surface flush with the top of the screen with liquid concave top
/// shoulders and rounded bottom corners, so the notch and whatever drops down read as one object.
struct IslandLayout: Equatable {
    var mode: IslandMode = .collapsed
    var showsMedia = false     // expanded content includes the Now Playing card
    var showsFooter = false    // expanded content includes the recent-notification / hint line
    var compactEars = false    // compact state has something to show beside the notch

    // User-configurable horizontal & vertical island dimensions (Settings ▸ General ▸ Dynamic Island Size).
    var customWidth: CGFloat = IslandLayout.defaultShadeWidth
    var customHeight: CGFloat = IslandLayout.defaultShadeHeight
    var compactWidthOffset: CGFloat = 0
    var compactHeightOffset: CGFloat = 0

    static let earWidth: CGFloat = 34
    static let nonNotchCompactWidth: CGFloat = 236
    static let defaultShadeWidth: CGFloat = 416
    static let defaultShadeHeight: CGFloat = 620
    static let shadeWidth: CGFloat = 416
    static let launcherWidth: CGFloat = 600

    // Max heights of the open content below the notch; the black surface hugs the real content.
    static let activityMaxHeight: CGFloat = 70
    static let expandedMaxHeight: CGFloat = 400
    static let bannerMaxHeight: CGFloat = 120
    static let shadeMaxHeight: CGFloat = 760
    static let launcherMaxHeight: CGFloat = 520

    var isBanner: Bool { mode == .banner }
    var isOpen: Bool { mode == .shade || mode == .launcher }

    /// Resting/compact vertical height of the Dynamic Island bar.
    func compactHeight(_ geo: NotchGeometry) -> CGFloat {
        geo.notchHeight + max(0, compactHeightOffset)
    }

    /// Horizontal ear width on notched MacBooks, incorporating any user compact-width adjustment.
    func effectiveEarWidth(_ geo: NotchGeometry) -> CGFloat {
        max(24, Self.earWidth + compactWidthOffset / 2)
    }

    /// Clamped vertical height budget for the Shade's scrollable content area on `geo.screen`.
    func shadeScrollHeight(_ geo: NotchGeometry) -> CGFloat {
        let maxOnScreen = max(240, geo.screen.visibleFrame.height - geo.notchHeight - 132)
        return max(240, min(customHeight, maxOnScreen))
    }

    /// Clamped vertical height for the Launcher results list.
    func launcherListHeight(_ geo: NotchGeometry) -> CGFloat {
        let scaled = customHeight * 0.62
        let maxOnScreen = max(220, geo.screen.visibleFrame.height - geo.notchHeight - 180)
        return max(220, min(max(360, scaled), maxOnScreen))
    }

    /// Outward concave fillet where the island meets the top bezel.
    var shoulderRadius: CGFloat {
        switch mode {
        case .collapsed, .compact: return 6
        case .volume, .activity: return 8
        default: return 10
        }
    }

    var cornerRadius: CGFloat {
        switch mode {
        case .collapsed, .compact: return compactHeightOffset > 6 ? 15 : 11
        case .volume: return 22
        case .activity: return 20
        default: return 28
        }
    }

    /// Usable inner body width of the island (excluding top bezel shoulder flares).
    func bodyWidth(_ geo: NotchGeometry) -> CGFloat {
        let w = geo.notchWidth
        let maxScreenBody = max(360, geo.screen.frame.width - 48)
        let targetOpen = min(maxScreenBody, max(360, customWidth))

        switch mode {
        case .collapsed:
            return min(maxScreenBody, max(w, w + max(0, compactWidthOffset)))
        case .compact:
            guard compactEars else {
                return min(maxScreenBody, max(w, w + max(0, compactWidthOffset)))
            }
            if geo.hasNotch {
                return min(maxScreenBody, w + 2 * effectiveEarWidth(geo))
            } else {
                return min(maxScreenBody, max(200, Self.nonNotchCompactWidth + compactWidthOffset))
            }
        case .volume:
            return min(targetOpen, max(w + 180, targetOpen * 0.88))
        case .activity:
            return min(targetOpen, max(w + 220, targetOpen * 0.85))
        case .banner, .expanded, .shade:
            return targetOpen
        case .launcher:
            return min(maxScreenBody, max(Self.launcherWidth, targetOpen + 110))
        }
    }

    /// Total width including the concave top-bezel shoulders on each side.
    func surfaceWidth(_ geo: NotchGeometry) -> CGFloat {
        bodyWidth(geo) + shoulderRadius * 2
    }
}
