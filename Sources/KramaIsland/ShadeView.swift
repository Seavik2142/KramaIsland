import Combine
import SwiftUI

/// The notification-shade content, drawn directly on the island's black surface: a grabber, the
/// clock, quick toggles, timer, next event, Now Playing, shelf, clipboard, then app-grouped
/// notifications.
struct ShadeContent: View {
    @ObservedObject var state: IslandState
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var updater = Updater.shared
    @ObservedObject var shelf: ShelfStore
    @ObservedObject var clipboard: ClipboardHistory
    @ObservedObject var calendar: CalendarModule
    @State private var now = Date()
    @State private var copied: String?
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    init(state: IslandState) {
        self.state = state
        self.shelf = state.shelf
        self.clipboard = state.clipboard
        self.calendar = state.calendar
    }

    var body: some View {
        VStack(spacing: 12) {
            grabber
            header
            ScrollView {
                VStack(spacing: UI.stack) {
                    if settings.quickTogglesEnabled { QuickTogglesRow(state: state) }
                    if settings.windowSnapEnabled {
                        WindowSnapCard(manager: state.windowManager) { state.closeShade() }
                    }
                    if state.showMirror {
                        CameraMirrorView()
                            .frame(height: 190)
                            .clipShape(RoundedRectangle(cornerRadius: UI.cardRadius, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: UI.cardRadius, style: .continuous)
                                .strokeBorder(UI.cardEdge, lineWidth: 1))
                            .transition(.opacity)
                    }
                    if settings.timerEnabled { TimerCard(engine: state.timer) }
                    if settings.calendarEnabled { CalendarRow(calendar: calendar) }
                    if let media = state.media {
                        ShadeMediaCard(media: media, controller: state.mediaController)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    } else if settings.volumeHUDEnabled {
                        ShadeVolumeCard(volume: state.volume)
                    }
                    if settings.shelfEnabled, !shelf.items.isEmpty { ShelfStrip(shelf: shelf) }
                    if settings.clipboardEnabled { clipboardSection }
                    if state.hasNotifications {
                        NotificationHubSection(state: state)
                    } else if state.media == nil, !state.showMirror {
                        empty
                    }
                }
                .padding(.bottom, 2)
            }
            .frame(maxHeight: 620)
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .foregroundStyle(.white)
        .onReceive(clock) { now = $0 }
    }

    private var grabber: some View {
        Capsule()
            .fill(.white.opacity(0.22))
            .frame(width: 34, height: 4)
            .contentShape(Rectangle().inset(by: -10))
            .onTapGesture { state.closeShade() }
    }

    /// Clock + date on the left (like a phone's shade), actions on the right.
    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(now, format: .dateTime.hour().minute())
                    .font(UI.numeral(23))
                    .tracking(-0.3)
                    .monospacedDigit()
                Text(now, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(UI.secondaryText)
            }
            Spacer()
            IconButton(symbol: "magnifyingglass", size: 30, help: "Search (\(settings.hotkeyDescription))") {
                state.openLauncherFromShade()
            }
            IconButton(symbol: "gearshape.fill", size: 30, help: "Settings") { SettingsWindowController.shared.show() }
            if let release = updater.available {
                PillButton(title: "Update", symbol: "arrow.down.circle.fill", prominent: true,
                           help: "KramaIsland \(release.version) is available: see what's new and update") {
                    SettingsWindowController.shared.show(tab: "updates")
                }
            }
            if state.hasNotifications {
                PillButton(title: "Clear All") { state.clearAll() }
            }
        }
        .padding(.horizontal, 4)
    }

    private var clipboardSection: some View {
        let items = state.showAllClipboard ? clipboard.items : Array(clipboard.items.prefix(5))
        return VStack(alignment: .leading, spacing: 0) {
            Eyebrow(symbol: "doc.on.clipboard.fill", "Clipboard", count: clipboard.items.isEmpty ? nil : clipboard.items.count) {
                if settings.clearClipboardOnShutdown {
                    HStack(spacing: 3) {
                        Image(systemName: "power").font(.system(size: 8, weight: .bold))
                        Text("Auto-clears").font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(UI.secondaryText)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(Color.white.opacity(0.07), in: Capsule())
                    .help("Clears automatically when your Mac shuts down or restarts")
                }
                if clipboard.items.count > 5 {
                    PillButton(title: state.showAllClipboard ? "Less" : "All \(clipboard.items.count)", small: true) {
                        withAnimation(Motion.quick) { state.showAllClipboard.toggle() }
                    }
                }
                if !clipboard.items.isEmpty {
                    IconButton(symbol: "xmark", size: 22, help: "Clear clipboard history") { clipboard.clear() }
                }
            }
            .padding(.bottom, items.isEmpty ? 6 : 8)

            if items.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(UI.tertiaryText)
                    Text(settings.clearClipboardOnShutdown
                         ? "Nothing copied yet — copies stay for this session and clear on shutdown."
                         : "Copy text anywhere to collect it here.")
                        .font(UI.body(10.5))
                        .foregroundStyle(UI.secondaryText)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { HairlineDivider() }
                    ClipboardItemRow(
                        item: item,
                        isCopied: copied == item.text,
                        onCopy: {
                            clipboard.copy(item)
                            withAnimation(Motion.quick) { copied = item.text }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                withAnimation(Motion.quick) { if copied == item.text { copied = nil } }
                            }
                        },
                        onRemove: { clipboard.remove(item) }
                    )
                }
            }
        }
        .islandCard(padding: 12)
    }

    private var empty: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: "bell.slash.fill", tint: UI.secondaryText, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("No notifications").font(UI.title(12.5))
                Text("You're all caught up").font(UI.body(10.5)).foregroundStyle(UI.secondaryText)
            }
            Spacer()
        }
        .islandCard(padding: 12)
    }
}

/// One session clipboard entry: source app icon, crisp preview, timestamp, click-to-copy, and
/// hover-revealed delete button.
private struct ClipboardItemRow: View {
    let item: ClipboardHistory.Item
    let isCopied: Bool
    let onCopy: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            if let icon = item.sourceIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: item.text.hasPrefix("http") ? "link" : "doc.text")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(UI.secondaryText)
                    .frame(width: 18, height: 18)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.text.replacingOccurrences(of: "\n", with: " "))
                    .font(UI.body(11))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                if let app = item.sourceAppName {
                    Text("\(app) · \(NotificationBannerView.relative(item.date))")
                        .font(UI.caption(9.5))
                        .foregroundStyle(UI.tertiaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isCopied {
                Label("Copied", systemImage: "checkmark")
                    .font(UI.caption())
                    .foregroundStyle(UI.success)
                    .transition(.opacity)
            } else if hovering {
                IconButton(symbol: "xmark", size: 18, help: "Remove entry", action: onRemove)
            } else if item.sourceAppName == nil {
                Text(NotificationBannerView.relative(item.date))
                    .font(UI.caption())
                    .foregroundStyle(UI.secondaryText)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(hovering ? Color.white.opacity(0.06) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onCopy)
        .animation(Motion.quick, value: hovering)
        .help("Click to copy")
    }
}

// MARK: - Quick toggles

/// Six Control Center-style modules in a clean 3×2 grid: Dark Mode, Keep Awake, Wi-Fi, Mirror,
/// Quiet, Focus. Each lights up its own circular glyph with a distinct semantic tint rather than
/// turning the entire tile white.
struct QuickTogglesRow: View {
    @ObservedObject var state: IslandState
    @ObservedObject private var caffeine = Caffeine.shared
    @ObservedObject private var status: SystemStatus
    @State private var dark = QuickSystem.isDarkMode
    @State private var wifi: Bool?

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
    private static let darkTint = Color(red: 0.44, green: 0.54, blue: 1.00)
    private static let quietTint = Color(red: 0.96, green: 0.44, blue: 0.50)

    init(state: IslandState) {
        self.state = state
        self.status = state.status
    }

    var body: some View {
        LazyVGrid(columns: Self.columns, spacing: 8) {
            ControlModule(
                symbol: dark ? "moon.stars.fill" : "sun.max.fill",
                title: "Dark Mode",
                status: dark ? "On" : "Off",
                on: dark,
                tint: Self.darkTint,
                help: "Toggle dark mode"
            ) {
                dark.toggle()
                QuickSystem.toggleDarkMode()
            }
            ControlModule(
                symbol: "cup.and.saucer.fill",
                title: "Keep Awake",
                status: caffeine.isOn ? "On" : "Off",
                on: caffeine.isOn,
                tint: UI.mic,
                help: "Keep the display awake"
            ) {
                caffeine.toggle()
            }
            ControlModule(
                symbol: wifi == false ? "wifi.slash" : "wifi",
                title: "Wi-Fi",
                status: wifi == true ? "On" : (wifi == false ? "Off" : "…"),
                on: wifi ?? false,
                tint: UI.info,
                help: "Toggle Wi-Fi"
            ) {
                guard let current = wifi else { return }
                wifi = !current
                DispatchQueue.global(qos: .userInitiated).async { QuickSystem.setWifi(!current) }
            }
            ControlModule(
                symbol: "camera.fill",
                title: "Mirror",
                status: state.showMirror ? "Live" : "Off",
                on: state.showMirror,
                tint: UI.camera,
                help: "Camera check"
            ) {
                withAnimation(Motion.quick) { state.showMirror.toggle() }
            }
            ControlModule(
                symbol: state.isQuiet ? "bell.slash.fill" : "bell.fill",
                title: "Quiet",
                status: state.isQuiet ? "On" : "Off",
                on: state.isQuiet,
                tint: Self.quietTint,
                help: state.quietReason ?? "Quiet Mode: nothing pops out of the notch"
            ) {
                if state.isQuiet, !state.settings.quietManualOn {
                    SettingsWindowController.shared.show(tab: "visibility")   // quiet because of Focus
                } else {
                    state.toggleQuiet()
                }
            }
            ControlModule(
                symbol: "moon.fill",
                title: "Focus",
                status: status.focusName ?? "Off",
                on: status.focusName != nil,
                tint: UI.focus,
                help: status.focusName.map { "\($0) is on · Manage Focus in System Settings" }
                      ?? "Manage Focus in System Settings"
            ) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .onAppear {
            dark = QuickSystem.isDarkMode
            DispatchQueue.global(qos: .utility).async {
                let on = QuickSystem.wifiIsOn()
                DispatchQueue.main.async { wifi = on }
            }
        }
    }
}

// MARK: - Notification Hub & Collapsible App Cards

struct NotificationHubSection: View {
    @ObservedObject var state: IslandState

    private var categories: [NotchNotification.Category] {
        state.availableNotificationCategories
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section summary + smart category filter strip
            HStack(spacing: 6) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(UI.info)
                Text("NOTIFICATIONS")
                    .font(UI.eyebrow)
                    .tracking(0.6)
                    .foregroundStyle(UI.secondaryText)
                Text("\(state.unreadCount)")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(UI.controlFill, in: Capsule())
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)

            if categories.count >= 2 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        filterChip(title: "All", symbol: nil, selected: state.selectedNotificationCategory == nil) {
                            withAnimation(Motion.quick) { state.selectedNotificationCategory = nil }
                        }
                        ForEach(categories) { cat in
                            filterChip(title: cat.rawValue, symbol: cat.symbol, selected: state.selectedNotificationCategory == cat) {
                                withAnimation(Motion.quick) {
                                    state.selectedNotificationCategory = (state.selectedNotificationCategory == cat) ? nil : cat
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }

            ForEach(state.groups) { group in
                NotificationGroupCard(group: group, state: state)
            }
        }
    }

    private func filterChip(title: String, symbol: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                }
                Text(title).font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(selected ? Color.black : .white.opacity(0.84))
            .padding(.horizontal, 9)
            .frame(height: 23)
            .background(selected ? Color.white.opacity(0.92) : UI.controlFill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct NotificationGroupCard: View {
    let group: NotificationGroup
    @ObservedObject var state: IslandState
    @State private var expanded = false
    @State private var headerHovering = false

    private static let collapsedLimit = 3

    private var visibleNotes: [NotchNotification] {
        expanded ? group.notes : Array(group.notes.prefix(Self.collapsedLimit))
    }

    private var hiddenCount: Int {
        max(0, group.notes.count - Self.collapsedLimit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(image: group.icon, group.appName, count: group.notes.count) {
                if headerHovering {
                    IconButton(symbol: "bell.slash.fill", size: 22, help: "Mute \(group.appName) notifications") {
                        state.muteNotifications(for: group.bundleID, appName: group.appName)
                    }
                    .transition(.opacity)
                }
                IconButton(symbol: "xmark", size: 22, help: "Clear \(group.appName)") {
                    state.dismissGroup(group)
                }
            }
            .padding(.bottom, 8)
            .onHover { headerHovering = $0 }
            .animation(Motion.quick, value: headerHovering)

            ForEach(Array(visibleNotes.enumerated()), id: \.element.id) { index, note in
                if index > 0 { HairlineDivider().padding(.vertical, 6) }
                NotificationRow(
                    note: note,
                    onOpen: { state.open(note) },
                    onDismiss: { state.dismiss(note) },
                    onMuteApp: { state.muteNotifications(for: note.bundleID, appName: note.appName) },
                    onCopyOTP: { code in state.copyOTP(code) },
                    onOpenURL: { url in state.openNotificationURL(url, note: note) }
                )
            }

            if hiddenCount > 0 {
                HairlineDivider().padding(.vertical, 6)
                Button {
                    withAnimation(Motion.quick) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                        Text(expanded ? "Show fewer" : "Show \(hiddenCount) more from \(group.appName)")
                            .font(.system(size: 10.5, weight: .semibold))
                        Spacer()
                    }
                    .foregroundStyle(UI.secondaryText)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .islandCard(padding: 12)
    }
}

struct NotificationRow: View {
    let note: NotchNotification
    let onOpen: () -> Void
    let onDismiss: () -> Void
    let onMuteApp: () -> Void
    let onCopyOTP: (String) -> Void
    let onOpenURL: (URL) -> Void

    @ObservedObject private var settings = AppSettings.shared
    @State private var hovering = false
    @State private var copiedCode = false

    private var hideBody: Bool { settings.privacyHideNotificationBody }
    private var showsSubtitle: Bool { !hideBody && !note.title.isEmpty && !note.subtitle.isEmpty }
    private var activeOTP: String? { (!hideBody && settings.notificationDetectOTP) ? note.otpCode : nil }
    private var activeURL: URL? { hideBody ? nil : note.actionURL }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 6) {
                Text(note.headline)
                    .font(UI.title(12.5))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if hovering {
                    IconButton(symbol: "xmark", size: 18, help: "Dismiss", action: onDismiss)
                } else {
                    Text(NotificationBannerView.relative(note.date))
                        .font(UI.caption())
                        .foregroundStyle(UI.secondaryText)
                }
            }

            if showsSubtitle {
                Text(note.subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.84))
                    .lineLimit(1)
            }

            if hideBody {
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(UI.warning)
                    Text("Notification content hidden")
                }
                .font(UI.body(11))
                .foregroundStyle(UI.secondaryText)
            } else if !note.body.isEmpty {
                Text(note.body)
                    .font(UI.body(11))
                    .foregroundStyle(UI.secondaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if activeOTP != nil || activeURL != nil {
                HStack(spacing: 6) {
                    if let code = activeOTP {
                        Button {
                            copiedCode = true
                            onCopyOTP(code)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copiedCode = false }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: copiedCode ? "checkmark" : "key.fill")
                                    .font(.system(size: 8.5, weight: .bold))
                                Text(copiedCode ? "Copied" : "Copy \(code)")
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                            }
                            .foregroundStyle(copiedCode ? Color.black : .white)
                            .padding(.horizontal, 8)
                            .frame(height: 21)
                            .background(copiedCode ? UI.success : UI.info.opacity(0.28), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    if let url = activeURL {
                        Button { onOpenURL(url) } label: {
                            HStack(spacing: 4) {
                                Image(systemName: note.isMeetingLink ? "video.fill" : "arrow.up.right")
                                    .font(.system(size: 8.5, weight: .bold))
                                Text(note.isMeetingLink ? "Join" : "Open Link")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .frame(height: 21)
                            .background((note.isMeetingLink ? UI.success : UI.info).opacity(0.24), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(.top, 3)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Color.white.opacity(0.055) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
        .animation(Motion.quick, value: hovering)
        .contextMenu {
            Button("Open \(note.appName)") { onOpen() }
            if let code = activeOTP {
                Button("Copy Code \(code)") { onCopyOTP(code) }
            }
            if !hideBody {
                Button("Copy Text") {
                    let text = [note.title, note.subtitle, note.body].filter { !$0.isEmpty }.joined(separator: "\n")
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(text, forType: .string)
                }
            }
            Divider()
            Button("Mute \(note.appName) Notifications") { onMuteApp() }
            Button("Clear") { onDismiss() }
        }
    }
}
