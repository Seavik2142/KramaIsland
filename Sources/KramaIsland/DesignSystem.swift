import AppKit
import SwiftUI

/// The island's shared visual language. Every card, icon, button and tint drawn on the black
/// surface comes from here, so the notch, the HUD, the hover readout, the shade and the launcher
/// read as one product instead of five.
enum UI {
    // Radii
    static let cardRadius: CGFloat = 20
    static let tileRadius: CGFloat = 14

    // Spacing
    static let cardPadding: CGFloat = 14
    static let stack: CGFloat = 8           // between cards

    // Fills on black
    static var cardFill: Color { .white.opacity(AppSettings.shared.translucentShade ? 0.10 : 0.065) }
    static let cardHoverFill = Color.white.opacity(0.10)
    static let cardStroke = Color.white.opacity(0.07)
    /// Hairline edge that is brighter along the top, like light catching the rim of glass.
    static let cardEdge = LinearGradient(colors: [.white.opacity(0.15), .white.opacity(0.04)],
                                         startPoint: .top, endPoint: .bottom)
    static let controlFill = Color.white.opacity(0.11)
    static let controlHoverFill = Color.white.opacity(0.17)
    static let track = Color.white.opacity(0.14)
    static let divider = Color.white.opacity(0.08)

    // Text on black
    static let secondaryText = Color.white.opacity(0.58)
    static let tertiaryText = Color.white.opacity(0.36)

    // Semantic tints — match the macOS indicators and apps where one exists.
    static let focus = Color(red: 0.71, green: 0.57, blue: 1.00)
    static let mic = Color(red: 1.00, green: 0.63, blue: 0.24)
    static let camera = Color(red: 0.33, green: 0.86, blue: 0.47)
    static let success = Color(red: 0.36, green: 0.86, blue: 0.48)
    static let warning = Color(red: 1.00, green: 0.80, blue: 0.27)
    static let danger = Color(red: 1.00, green: 0.40, blue: 0.38)
    static let info = Color(red: 0.42, green: 0.70, blue: 1.00)
    static let timer = Color(red: 1.00, green: 0.62, blue: 0.04)     // the Clock app's orange
    static let muted = Color.white.opacity(0.55)

    // Type scale
    static func title(_ size: CGFloat = 13) -> Font { .system(size: size, weight: .semibold) }
    static func body(_ size: CGFloat = 11) -> Font { .system(size: size) }
    static func caption(_ size: CGFloat = 9.5) -> Font { .system(size: size, weight: .medium) }
    static func numeral(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
    static let eyebrow: Font = .system(size: 9.5, weight: .semibold)
}

// MARK: - Surfaces

/// The one card style: soft fill, a top-lit hairline edge, continuous corners. `tint` washes the
/// card with a colour (the Now Playing card takes it from the artwork).
struct IslandCard: ViewModifier {
    var padding: CGFloat = UI.cardPadding
    var tint: Color? = nil

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: UI.cardRadius, style: .continuous)
        content
            .padding(padding)
            .background {
                ZStack {
                    shape.fill(UI.cardFill)
                    if let tint {
                        shape.fill(LinearGradient(colors: [tint.opacity(0.36), tint.opacity(0.08)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing))
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.45), value: tint)
            }
            .overlay(shape.strokeBorder(UI.cardEdge, lineWidth: 1))
    }
}

extension View {
    func islandCard(padding: CGFloat = UI.cardPadding, tint: Color? = nil) -> some View {
        modifier(IslandCard(padding: padding, tint: tint))
    }
}

struct HairlineDivider: View {
    var body: some View { Rectangle().fill(UI.divider).frame(height: 1) }
}

// MARK: - Icons

/// A glyph on a tinted rounded square: the one way an icon leads a row (HUD, launcher, timer,
/// calendar, empty states).
struct IconBadge: View {
    let symbol: String
    var tint: Color = .white
    var size: CGFloat = 32
    var filled = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(filled ? Theme.on(tint) : tint)
            .frame(width: size, height: size)
            .background(filled ? tint : tint.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

/// Round icon button: header actions and close marks. `tint` colours it (timer pause, etc.).
struct IconButton: View {
    let symbol: String
    var size: CGFloat = 28
    var tint: Color? = nil
    var help = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(tint ?? .white)
                .frame(width: size, height: size)
                .background(fill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .help(help)
    }

    private var fill: Color {
        if let tint { return tint.opacity(hovering ? 0.28 : 0.18) }
        return hovering ? UI.controlHoverFill : UI.controlFill
    }
}

/// Capsule text button. `prominent` fills it with the accent colour.
struct PillButton: View {
    let title: String
    var symbol: String? = nil
    var prominent = false
    var small = false
    var help = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: small ? 9 : 10, weight: .bold))
                }
                Text(title)
                    .font(.system(size: small ? 10.5 : 11.5, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(prominent ? Theme.onAccent : .white)
            .padding(.horizontal, small ? 10 : 12)
            .frame(height: small ? 24 : 28)
            .background(fill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .help(help)
    }

    private var fill: Color {
        if prominent { return Theme.accent.opacity(hovering ? 0.88 : 1) }
        return hovering ? UI.controlHoverFill : UI.controlFill
    }
}

/// Keyboard hint (⌥ Space, ↩).
struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(UI.controlFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Colour-coded status chip: Mic, Camera, Focus, Awake. Text never truncates; it goes icon-only
/// instead when the row asks for it.
struct StatusPill: View {
    let symbol: String
    let text: String
    let tint: Color
    var iconOnly = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            if !iconOnly {
                Text(text).font(.system(size: 9.5, weight: .semibold)).lineLimit(1).fixedSize()
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, iconOnly ? 7 : 8)
        .frame(height: 22)
        .background(tint.opacity(0.16), in: Capsule())
        .help(text)
    }
}

/// Section label inside a list card: 16 pt mark, UPPERCASE title, optional count, trailing controls.
struct Eyebrow<Trailing: View>: View {
    enum Mark { case symbol(String), image(NSImage) }

    let mark: Mark
    let title: String
    var count: Int? = nil
    @ViewBuilder let trailing: () -> Trailing

    init(symbol: String, _ title: String, count: Int? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.mark = .symbol(symbol); self.title = title; self.count = count; self.trailing = trailing
    }
    init(image: NSImage, _ title: String, count: Int? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.mark = .image(image); self.title = title; self.count = count; self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 7) {
            switch mark {
            case .symbol(let s):
                Image(systemName: s)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            case .image(let i):
                Image(nsImage: i).resizable().frame(width: 16, height: 16)
            }
            Text(title.uppercased())
                .font(UI.eyebrow)
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let count, count > 1 {
                Text("\(count)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(UI.controlFill, in: Capsule())
            }
            Spacer(minLength: 6)
            HStack(spacing: 6) { trailing() }
        }
    }
}

extension Eyebrow where Trailing == EmptyView {
    init(symbol: String, _ title: String, count: Int? = nil) {
        self.init(symbol: symbol, title, count: count) { EmptyView() }
    }
}

// MARK: - Controls

/// Horizontal progress track shared by the scrubber, the volume slider and HUD bars.
struct TrackBar: View {
    let fraction: Double
    var tint: Color = Theme.accent
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(UI.track)
                Capsule().fill(tint).frame(width: geo.size.width * CGFloat(max(0, min(1, fraction))))
            }
        }
        .frame(height: height)
    }
}

/// Control Center-style module: a round glyph that fills with the tint when on, a title and a
/// one-word state ("On", "Off", "Do Not Disturb"). Three fit a row of the shade without wrapping.
struct ControlModule: View {
    let symbol: String
    let title: String
    let status: String
    let on: Bool
    var tint: Color = Theme.accent
    var help = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: { Feedback.tap(); action() }) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(on ? Theme.on(tint) : .white)
                    .frame(width: 28, height: 28)
                    .background(on ? tint : UI.controlFill, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(status)
                        .font(.system(size: 10))
                        .foregroundStyle(UI.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.leading, 9)
            .padding(.trailing, 6)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(hovering ? UI.cardHoverFill : UI.cardFill,
                        in: RoundedRectangle(cornerRadius: UI.tileRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: UI.tileRadius, style: .continuous)
                .strokeBorder(UI.cardEdge, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: UI.tileRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: on)
        .help(help)
    }
}
