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

    static let earWidth: CGFloat = 34
    static let nonNotchCompactWidth: CGFloat = 236
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
        case .collapsed, .compact: return 11
        case .volume: return 22
        case .activity: return 20
        default: return 28
        }
    }

    /// Usable inner body width of the island (excluding top bezel shoulder flares).
    func bodyWidth(_ geo: NotchGeometry) -> CGFloat {
        let w = geo.notchWidth
        switch mode {
        case .collapsed:
            return w
        case .compact:
            guard compactEars else { return w }
            return geo.hasNotch ? w + 2 * Self.earWidth : Self.nonNotchCompactWidth
        case .volume:
            return min(Self.shadeWidth, max(w + 180, 366))
        case .activity:
            return min(Self.shadeWidth, max(w + 220, 340))
        case .banner, .expanded, .shade:
            return Self.shadeWidth
        case .launcher:
            return Self.launcherWidth
        }
    }

    /// Total width including the concave top-bezel shoulders on each side.
    func surfaceWidth(_ geo: NotchGeometry) -> CGFloat {
        bodyWidth(geo) + shoulderRadius * 2
    }
}
