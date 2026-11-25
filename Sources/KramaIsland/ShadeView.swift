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
                        ForEach(state.groups) { group in
                            NotificationGroupCard(group: group, state: state)
                        }
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

// MARK: - Notification cards

struct NotificationGroupCard: View {
    let group: NotificationGroup
    @ObservedObject var state: IslandState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(image: group.icon, group.appName, count: group.notes.count) {
                IconButton(symbol: "xmark", size: 22, help: "Clear \(group.appName)") { state.dismissGroup(group) }
            }
            .padding(.bottom, 8)

            ForEach(Array(group.notes.enumerated()), id: \.element.id) { index, note in
                if index > 0 { HairlineDivider().padding(.vertical, 8) }
                NotificationRow(note: note,
                                onOpen: { state.open(note) },
                                onDismiss: { state.dismiss(note) })
            }
        }
        .islandCard()
    }
}

struct NotificationRow: View {
    let note: NotchNotification
    let onOpen: () -> Void
    let onDismiss: () -> Void
    @ObservedObject private var settings = AppSettings.shared

    private var hideBody: Bool { settings.privacyHideNotificationBody }
    private var showsSubtitle: Bool { !hideBody && !note.title.isEmpty && !note.subtitle.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(note.headline)
                    .font(UI.title())
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(NotificationBannerView.relative(note.date))
                    .font(UI.caption())
                    .foregroundStyle(UI.secondaryText)
            }
            if showsSubtitle {
                Text(note.subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            if hideBody {
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold))
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button("Open") { onOpen() }
            Button("Clear") { onDismiss() }
        }
    }
}
