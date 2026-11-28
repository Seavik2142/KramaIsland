import SwiftUI
import Combine
import UniformTypeIdentifiers

/// The whole UI is one black surface flush with the top of the screen: flat top, rounded bottom.
/// It grows from the notch into the hover readout, a live-activity HUD, the banner, the shade or
/// the launcher, so the notch and whatever drops down always read as a single thing.
struct NotchView: View {
    @ObservedObject var state: IslandState
    let displayID: CGDirectDisplayID
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var updater = Updater.shared
    @State private var now = Date()
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var geo: NotchGeometry { state.geometry(for: displayID) }

    /// A window's worth of shadow: soft, mostly below the surface, a few points at the sides. None
    /// while the island is only the notch and its ears, which sit inside the menu bar.
    private func shadowOpacity(_ layout: IslandLayout) -> Double {
        guard settings.islandShadow else { return 0 }
        switch layout.mode {
        case .collapsed, .compact: return 0
        default: return 0.34
        }
    }

    var body: some View {
        surface
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onReceive(clock) { now = $0 }
    }

    private var surface: some View {
        let g = geo
        let layout = state.layout(for: displayID)

        // The surface takes the height of the *current* state only, so it springs smoothly between
        // sizes while the outgoing state fades out on top of the incoming one (clipped by the shape)
        // instead of stacking above it and pushing it down.
        let shape = IslandSurfaceShape(radius: layout.cornerRadius, shoulder: layout.shoulderRadius)
        return IslandSurfaceLayout(mode: layout.mode) {
            content(layout, g)
        }
        .frame(width: layout.bodyWidth(g))
        .padding(.horizontal, layout.shoulderRadius)
        .background(Color.black)
        .clipShape(shape)
        .overlay {
            if layout.mode != .collapsed && layout.mode != .compact {
                IslandSurfaceBorderShape(radius: layout.cornerRadius, shoulder: layout.shoulderRadius)
                    .stroke(
                        LinearGradient(colors: [.white.opacity(0.05), .white.opacity(0.14)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.75
                    )
                    .allowsHitTesting(false)
            } else if !g.hasNotch {
                // Crisp subtle glass edge on external / non-notch displays so the resting pill reads cleanly.
                IslandSurfaceBorderShape(radius: layout.cornerRadius, shoulder: layout.shoulderRadius)
                    .stroke(Color.white.opacity(0.11), lineWidth: 0.6)
                    .allowsHitTesting(false)
            }
        }
        .background {
            // Cast the shadow from a standalone solid black shape behind the clipped surface so
            // CoreAnimation never re-rasterizes the full view subtree to build a shadow mask.
            if shadowOpacity(layout) > 0 {
                shape
                    .fill(Color.black)
                    .shadow(color: .black.opacity(shadowOpacity(layout)), radius: 12, y: 5)
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { reportSurfaceSize(proxy.size) }
                    .onChange(of: proxy.size) { reportSurfaceSize($0) }
            }
        )
        .contentShape(shape)
        .onTapGesture {
            switch layout.mode {
            case .banner, .volume: break    // interactive HUD / banner handles its own taps & buttons
            case .activity:
                if state.activity?.kind == .update {
                    ActivityCenter.shared.dismiss(id: "update")
                    if let release = Updater.shared.activeAlertRelease {
                        UpdateAlertWindowController.shared.show(release: release, isPreview: Updater.shared.previewRelease != nil)
                    } else {
                        SettingsWindowController.shared.show(tab: "updates")
                    }
                } else {
                    state.activities.dismissByUser()
                }
            case .collapsed, .compact, .expanded: state.toggleShade(on: displayID)
            case .shade, .launcher: break   // inner controls handle taps
            }
        }
        .onDrop(of: ShelfStore.acceptedDropTypes, isTargeted: Binding(
            get: { state.isDragTargeted && state.activeDisplayID == displayID },
            set: { state.setDragTargeted($0, on: displayID) }
        )) { providers in
            guard settings.airDropEnabled || settings.shelfEnabled else { return false }
            ShelfStore.resolveDroppedURLs(from: providers) { urls, temps in
                state.setDragTargeted(false, on: displayID)
                guard !urls.isEmpty else { return }
                if settings.airDropEnabled && !settings.shelfEnabled {
                    AirDropManager.shared.send(urls, temporaryURLs: temps)
                } else {
                    state.shelf.add(urls)
                    state.openShade(on: displayID)
                }
            }
            return true
        }
        .animation(Motion.spring, value: layout)
    }

    private func reportSurfaceSize(_ size: CGSize) {
        state.setRenderedSurfaceSize(size, for: displayID)
    }

    private func notchClearance(_ g: NotchGeometry) -> some View {
        Color.clear.frame(height: g.notchHeight)
    }

    @ViewBuilder
    private func content(_ layout: IslandLayout, _ g: NotchGeometry) -> some View {
        switch layout.mode {
        case .collapsed:
            Color.clear.frame(width: layout.bodyWidth(g), height: layout.compactHeight(g))
                .islandBranch(.collapsed)

        case .compact:
            ZStack {
                Color.clear.frame(height: layout.compactHeight(g))
                if layout.compactEars {
                    CompactEars(state: state, timer: state.timer, status: state.status, geo: g, layout: layout)
                }
            }
            .islandBranch(.compact)

        case .volume:
            VStack(spacing: 0) {
                notchClearance(g)
                VolumeHUDView(volume: state.volume)
            }
            .islandBranch(.volume)

        case .activity:
            VStack(spacing: 0) {
                notchClearance(g)
                if let a = state.activity {
                    ActivityHUD(activity: a).id(a.id).transition(.opacity)
                }
            }
            .islandBranch(.activity)

        case .banner:
            VStack(spacing: 0) {
                notchClearance(g)
                if let note = state.banner {
                    NotificationBannerView(
                        note: note,
                        queueCount: state.bannerQueueCount,
                        isHovered: state.isBannerHovered,
                        duration: state.bannerDuration,
                        onOpen: { state.openBanner() },
                        onDismiss: { state.dismissBanner() },
                        onOpenShade: { state.openShadeFromBanner() },
                        onMuteApp: { state.muteNotifications(for: note.bundleID, appName: note.appName) },
                        onCopyOTP: { code in state.copyOTP(code, dismissBannerAfter: true) },
                        onOpenURL: { url in state.openNotificationURL(url, note: note) }
                    )
                    .id(note.id)
                    .transition(.opacity)
                }
            }
            .islandBranch(.banner)

        case .expanded:
            VStack(spacing: 0) {
                notchClearance(g)
                expandedContent
            }
            .islandBranch(.expanded)

        case .shade:
            VStack(spacing: 0) {
                notchClearance(g)
                ShadeContent(state: state)
            }
            .islandBranch(.shade)

        case .launcher:
            VStack(spacing: 0) {
                notchClearance(g)
                LauncherView(state: state, engine: state.launcher)
            }
            .islandBranch(.launcher)
        }
    }

    // MARK: Hover (expanded) content

    private var expandedContent: some View {
        VStack(spacing: UI.stack) {
            if state.isDragTargeted && (settings.airDropEnabled || settings.shelfEnabled) {
                IslandDropZonesView(state: state, displayID: displayID)
            } else {
                statusRow
                if state.volumeHUDVisible {
                    InlineVolumeRow(volume: state.volume)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if settings.timerEnabled, state.timerActive {
                    TimerCard(engine: state.timer)
                }
                if settings.calendarEnabled, state.calendar.next != nil {
                    CalendarRow(calendar: state.calendar)
                }
                if let media = state.media {
                    MediaCard(media: media, controller: state.mediaController)
                }
                if let release = updater.available {
                    updateRow(release)
                }
                if let note = state.footerNotification {
                    recentRow(note)
                } else if let hint = state.hint {
                    hintRow(hint)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    /// Clock and date on the left; status chips, battery capsule and notification bell on the right.
    private var statusRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(now, format: .dateTime.hour().minute())
                    .font(UI.numeral(22))
                    .tracking(-0.3)
                    .monospacedDigit()
                Text(now, format: .dateTime.weekday(.wide).day().month(.abbreviated))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(UI.secondaryText)
            }
            Spacer(minLength: 6)
            if settings.indicatorsEnabled {
                IndicatorStrip(status: state.status, caffeine: state.caffeine, quiet: state.isQuiet)
            }
            BatteryBadge(status: state.status)
            notificationsButton
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }

    private var notificationsButton: some View {
        let count = state.unreadCount
        return IconButton(symbol: "bell.fill", size: 28, help: "Open Shade") { state.toggleShade(on: displayID) }
            .overlay(alignment: .topTrailing) {
                if count > 0 {
                    Text(count > 99 ? "99+" : "\(count)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 15, minHeight: 15)
                        .background(UI.danger, in: Capsule())
                        .offset(x: 4, y: -3)
                }
            }
    }

    private func recentRow(_ note: NotchNotification) -> some View {
        let hide = settings.privacyHideNotificationBody
        let line = hide
            ? note.headline
            : note.headline + (note.body.isEmpty ? "" : " · " + note.body)
        return HStack(spacing: 10) {
            Image(nsImage: note.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Circle().fill(note.category.tint).frame(width: 4.5, height: 4.5)
                    Text(note.sourceLabel.uppercased()).font(UI.eyebrow).tracking(0.5).foregroundStyle(UI.secondaryText)
                }
                Text(line)
                    .font(UI.body(11))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if !hide, settings.notificationDetectOTP, let code = note.otpCode {
                Button { state.copyOTP(code) } label: {
                    Text(code)
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(UI.info.opacity(0.32), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Copy verification code \(code)")
            } else {
                Text(NotificationBannerView.relative(note.date))
                    .font(UI.caption())
                    .foregroundStyle(UI.secondaryText)
            }
            IconButton(symbol: "xmark", size: 20, help: "Clear") { state.clearLatest() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(UI.cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(UI.cardEdge, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { state.open(note) }
    }

    /// A subtle, dismissible footer banner for permissions or setup tips.
    private func hintRow(_ hint: IslandHint) -> some View {
        let isAction = hint.settingsPane != nil
        let tint = isAction ? UI.warning : UI.info
        let symbol = isAction ? "exclamationmark.triangle.fill" : "info.circle.fill"
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        return HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(hint.text)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(UI.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let pane = hint.settingsPane {
                PillButton(title: "Settings", small: true, help: "Open System Settings") {
                    PrivacyPane.open(pane)
                }
            }
            IconButton(symbol: "xmark", size: 20, help: "Dismiss") { state.dismissHint() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tint.opacity(0.08), in: shape)
        .overlay(shape.strokeBorder(tint.opacity(0.18), lineWidth: 0.75))
        .contentShape(shape)
        .onTapGesture { if let pane = hint.settingsPane { PrivacyPane.open(pane) } }
        .help(isAction ? "\(hint.text) Click to open System Settings." : hint.text)
    }

    /// A newer release is out; lets the user update in one click or inspect release notes.
    private func updateRow(_ release: AppRelease) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return HStack(spacing: 9) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(UI.info)
                .frame(width: 24, height: 24)
                .background(UI.info.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("Update Available · v\(release.version)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(1)
                Text("Tap for release notes or update in place")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(UI.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            PillButton(title: "Update", symbol: "arrow.down.circle.fill", prominent: true, small: true,
                       help: "Download and install KramaIsland \(release.version)") {
                Updater.shared.triggerPrimaryUpdateAction()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(UI.info.opacity(0.12), in: shape)
        .overlay(shape.strokeBorder(UI.info.opacity(0.28), lineWidth: 0.75))
        .contentShape(shape)
        .onTapGesture { UpdateAlertWindowController.shared.show(release: release, isPreview: false) }
        .help("View what's new in KramaIsland \(release.version)")
    }
}

// MARK: - Compact ears

/// Compact notch view:
/// - On notched MacBooks: sleek balanced 34 pt ears flanking the hardware camera cutout.
/// - On non-notch Macs & external displays: a unified Dynamic Island pill using the center space
///   for the live track title, timer, or active status.
struct CompactEars: View {
    @ObservedObject var state: IslandState
    @ObservedObject var timer: TimerEngine
    @ObservedObject var status: SystemStatus
    let geo: NotchGeometry
    let layout: IslandLayout

    var body: some View {
        let h = layout.compactHeight(geo)
        let earW = layout.effectiveEarWidth(geo)
        Group {
            if geo.hasNotch {
                HStack(spacing: 0) {
                    leftEar.frame(width: earW, height: h)
                    Spacer().frame(width: geo.notchWidth)
                    rightEar.frame(width: earW, height: h)
                }
            } else {
                HStack(spacing: 8) {
                    leftEar
                    nonNotchCenter
                    Spacer(minLength: 4)
                    rightEar
                }
                .padding(.horizontal, 10)
                .frame(height: h)
            }
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder private var nonNotchCenter: some View {
        if let media = state.media {
            Text(media.title.isEmpty ? media.platformName : media.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(media.isPlaying ? 0.94 : 0.65))
                .lineLimit(1)
        } else if let sticky = state.stickyActivity {
            Text(sticky.title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        } else if timer.isActive {
            Text("Timer")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(UI.timer)
                .lineLimit(1)
        } else if let focus = status.focusName {
            Text(focus)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(UI.focus)
                .lineLimit(1)
        } else if status.micInUse {
            Text("Mic Live")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(UI.mic)
                .lineLimit(1)
        } else if status.cameraInUse {
            Text("Camera")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(UI.camera)
                .lineLimit(1)
        } else if AppSettings.shared.notificationUnreadDot, state.hasNotifications {
            Text("\(state.unreadCount) Alert\(state.unreadCount == 1 ? "" : "s")")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
        }
    }

    @ViewBuilder private var leftEar: some View {
        if let media = state.media {
            let artSize: CGFloat = geo.hasNotch ? 20 : 18
            ZStack(alignment: .bottomTrailing) {
                ArtworkView(image: media.artwork, size: artSize, radius: 5, fallbackIcon: media.icon)
                if media.artwork != nil {
                    Image(nsImage: media.icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 9, height: 9)
                        .background(Color.black, in: Circle().inset(by: -1))
                        .offset(x: 2, y: 2)
                }
            }
        } else if let sticky = state.stickyActivity {
            if let image = sticky.image {
                Image(nsImage: image).resizable().frame(width: 18, height: 18)
            } else {
                earGlyph(sticky.symbol, sticky.tint)
            }
        } else if timer.isActive {
            TimerRing(progress: timer.progress, size: 16, lineWidth: 2.5)
        } else if status.focusName != nil {
            earGlyph("moon.fill", UI.focus)
        } else if status.micInUse {
            earGlyph("mic.fill", UI.mic)
        } else if status.cameraInUse {
            earGlyph("video.fill", UI.camera)
        } else if AppSettings.shared.notificationUnreadDot, state.hasNotifications {
            earGlyph("bell.badge.fill", UI.danger)
        }
    }

    @ViewBuilder private var rightEar: some View {
        if let media = state.media {
            LevelMeter(playing: media.isPlaying, tint: ArtworkPalette.color(for: media.artwork) ?? .white)
        } else if let sticky = state.stickyActivity {
            ActivityRing(progress: sticky.progress, tint: sticky.tint, size: 16)
                .help(sticky.title + (sticky.subtitle.isEmpty ? "" : " · " + sticky.subtitle))
        } else if timer.isActive {
            Text(timer.display)
                .font(UI.numeral(9.5))
                .foregroundStyle(UI.timer)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        } else if status.micInUse || status.cameraInUse || status.focusName != nil {
            HStack(spacing: 4) {
                if status.micInUse { Circle().fill(UI.mic).frame(width: 7, height: 7) }
                if status.cameraInUse { Circle().fill(UI.camera).frame(width: 7, height: 7) }
                if status.focusName != nil {
                    Image(systemName: "moon.fill").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(UI.focus)
                }
            }
        } else if AppSettings.shared.notificationUnreadDot, state.hasNotifications {
            Text(state.unreadCount > 9 ? "9+" : "\(state.unreadCount)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 5.5)
                .frame(minWidth: 16, minHeight: 16)
                .background(UI.danger, in: Capsule())
        }
    }

    private func earGlyph(_ symbol: String, _ tint: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
    }
}

/// Mic / Camera / Focus / Awake chips for the hover row. Full labels when there is room for them,
/// icon-only when three or more are lit, so a label like "Do Not Disturb" is never cut short.
struct IndicatorStrip: View {
    @ObservedObject var status: SystemStatus
    @ObservedObject var caffeine: Caffeine
    var quiet = false

    private struct Indicator: Identifiable {
        let id: String      // symbol
        let text: String
        let tint: Color
    }

    private var indicators: [Indicator] {
        var out: [Indicator] = []
        if status.micInUse { out.append(Indicator(id: "mic.fill", text: "Mic", tint: UI.mic)) }
        if status.cameraInUse { out.append(Indicator(id: "video.fill", text: "Camera", tint: UI.camera)) }
        if let f = status.focusName { out.append(Indicator(id: "moon.fill", text: f, tint: UI.focus)) }
        if quiet { out.append(Indicator(id: "bell.slash.fill", text: "Quiet", tint: .white)) }
        if caffeine.isOn { out.append(Indicator(id: "cup.and.saucer.fill", text: "Awake", tint: UI.mic)) }
        return out
    }

    var body: some View {
        let items = indicators
        HStack(spacing: 5) {
            ForEach(items) { item in
                // Quiet gives up its label first, so the clock beside it keeps its line.
                StatusPill(symbol: item.id, text: item.text, tint: item.tint,
                           iconOnly: items.count > 2 || (items.count > 1 && item.id == "bell.slash.fill"))
            }
        }
    }
}

// MARK: - Surface layout and transitions

/// Tags each state's content so the surface layout knows which one is current.
private struct SurfaceModeKey: LayoutValueKey {
    static let defaultValue: IslandMode? = nil
}

/// Stacks every state's content from the top (outgoing and incoming overlap during a transition)
/// and sizes itself to the current state alone. The content is offered the same space as before,
/// so nothing inside reflows; only the surface's own height changes, and it springs.
struct IslandSurfaceLayout: Layout {
    var mode: IslandMode

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let current = subviews.last(where: { $0[SurfaceModeKey.self] == mode }) ?? subviews.last else {
            return .zero
        }
        let size = current.sizeThatFits(proposal)
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for sub in subviews {
            sub.place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top,
                      proposal: ProposedViewSize(width: bounds.width, height: proposal.height))
        }
    }
}

/// Lightweight GPU-composited content reveal: opacity + top-anchored scale with no offscreen
/// blur filter, so the island expands and collapses smoothly at 120 fps.
private struct IslandReveal: ViewModifier {
    let shown: Bool

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : 0.96, anchor: .top)
    }
}

extension AnyTransition {
    static var islandContent: AnyTransition {
        if Motion.reduce { return .opacity }
        let reveal = AnyTransition.modifier(active: IslandReveal(shown: false), identity: IslandReveal(shown: true))
        return .asymmetric(
            insertion: reveal.animation(.spring(response: 0.30, dampingFraction: 0.86)),
            removal: reveal.animation(.easeOut(duration: 0.12)))
    }
}

private extension View {
    /// Marks the root of one state's content: tagged for the surface layout, with the reveal transition.
    func islandBranch(_ mode: IslandMode) -> some View {
        layoutValue(key: SurfaceModeKey.self, value: mode)
            .transition(.islandContent)
    }
}

/// The black surface: flush with the top bezel with smooth concave top shoulders and rounded
/// bottom corners, matching the real MacBook Pro notch profile.
struct IslandSurfaceShape: Shape {
    var radius: CGFloat
    var shoulder: CGFloat = 6

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(radius, shoulder) }
        set { radius = newValue.first; shoulder = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let s = max(0, min(shoulder, rect.width / 6, rect.height / 3))
        let innerMinX = rect.minX + s
        let innerMaxX = rect.maxX - s
        let r = max(0, min(radius, (innerMaxX - innerMinX) / 2, rect.height - s))

        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: innerMinX, y: rect.minY + s),
                       control: CGPoint(x: innerMinX, y: rect.minY))
        p.addLine(to: CGPoint(x: innerMinX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: innerMinX + r, y: rect.maxY),
                       control: CGPoint(x: innerMinX, y: rect.maxY))
        p.addLine(to: CGPoint(x: innerMaxX - r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: innerMaxX, y: rect.maxY - r),
                       control: CGPoint(x: innerMaxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: innerMaxX, y: rect.minY + s))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: innerMaxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// Open-top perimeter path for stroking only the visible side and bottom curves without drawing
/// a seam along the top screen bezel.
struct IslandSurfaceBorderShape: Shape {
    var radius: CGFloat
    var shoulder: CGFloat = 6

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(radius, shoulder) }
        set { radius = newValue.first; shoulder = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let inset: CGFloat = 0.5
        let s = max(0, min(shoulder, rect.width / 6, rect.height / 3))
        let innerMinX = rect.minX + s + inset
        let innerMaxX = rect.maxX - s - inset
        let bottom = rect.maxY - inset
        let r = max(0, min(radius - inset, (innerMaxX - innerMinX) / 2, bottom - s))

        var p = Path()
        p.move(to: CGPoint(x: rect.minX + inset, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: innerMinX, y: rect.minY + s),
                       control: CGPoint(x: innerMinX, y: rect.minY))
        p.addLine(to: CGPoint(x: innerMinX, y: bottom - r))
        p.addQuadCurve(to: CGPoint(x: innerMinX + r, y: bottom),
                       control: CGPoint(x: innerMinX, y: bottom))
        p.addLine(to: CGPoint(x: innerMaxX - r, y: bottom))
        p.addQuadCurve(to: CGPoint(x: innerMaxX, y: bottom - r),
                       control: CGPoint(x: innerMaxX, y: bottom))
        p.addLine(to: CGPoint(x: innerMaxX, y: rect.minY + s))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - inset, y: rect.minY),
                       control: CGPoint(x: innerMaxX, y: rect.minY))
        return p
    }
}

struct BatteryBadge: View {
    @ObservedObject var status: SystemStatus

    var body: some View {
        let info = status.battery
        let tint: Color = info.onAC ? UI.success
            : info.percent <= 20 ? UI.danger
            : info.percent <= 30 ? UI.warning
            : .white.opacity(0.88)
        HStack(spacing: 5) {
            Image(systemName: Self.symbol(percent: info.percent, onAC: info.onAC))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text("\(info.percent)%")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(info.percent <= 20 && !info.onAC ? UI.danger : .white.opacity(0.92))
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(UI.controlFill, in: Capsule())
        .overlay(Capsule().strokeBorder(UI.cardStroke, lineWidth: 0.75))
        .help(info.onAC ? "Charging · \(info.percent)%" : "On battery · \(info.percent)%")
    }

    static func symbol(percent: Int, onAC: Bool) -> String {
        if onAC { return "battery.100percent.bolt" }
        switch percent {
        case ..<10: return "battery.0percent"
        case ..<35: return "battery.25percent"
        case ..<60: return "battery.50percent"
        case ..<85: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}
