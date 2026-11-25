import AppKit
import ApplicationServices
import EventKit
import SwiftUI

extension Notification.Name {
    static let notchHotkeyChanged = Notification.Name("KramaIsland.hotkeyChanged")
    static let notchModulesChanged = Notification.Name("KramaIsland.modulesChanged")
}

/// Which Settings pane is showing; shared so the menu bar, the island and the updater can pick one.
final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()
    @Published var tab = ProcessInfo.processInfo.environment["KRAMAISLAND_SETTINGS_TAB"] ?? "general"
}

enum BrandIcon {
    /// Loads AppIcon.icns directly from the bundle so Settings, Updates, About, and alerts always
    /// display the latest icon rather than a stale LaunchServices cache.
    static let image: NSImage = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return NSApp.applicationIconImage
    }()
}

final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(tab: String? = nil) {
        if let tab { SettingsRouter.shared.tab = tab }
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 740, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            w.title = "KramaIsland Settings"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.contentView = NSHostingView(rootView: SettingsView())
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Sidebar model

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general, modules, visibility, permissions, updates, about

    var id: String { rawValue }

    var sidebarTitle: String {
        switch self {
        case .permissions: return "Privacy"
        default: return title
        }
    }

    var title: String {
        switch self {
        case .general: return "General"
        case .modules: return "Modules"
        case .visibility: return "Visibility"
        case .permissions: return "Privacy & Permissions"
        case .updates: return "Updates"
        case .about: return "About"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Startup, global shortcut, interaction feel, and accent theme."
        case .modules: return "Choose which live activities and shade cards appear in the island."
        case .visibility: return "Quiet Mode, auto-hide rules, and multi-display placement."
        case .permissions: return "Control on-device privacy protections, macOS permissions, and local data."
        case .updates: return "Check GitHub Releases and install signed updates in place."
        case .about: return "Version details, signing certificate, and open-source links."
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .modules: return "square.grid.2x2.fill"
        case .visibility: return "eye.fill"
        case .permissions: return "lock.shield.fill"
        case .updates: return "arrow.down.circle.fill"
        case .about: return "sparkles"
        }
    }

    var tint: Color {
        switch self {
        case .general: return Color(red: 0.45, green: 0.52, blue: 0.62)
        case .modules: return Color(red: 0.38, green: 0.48, blue: 0.98)
        case .visibility: return Color(red: 0.68, green: 0.44, blue: 0.98)
        case .permissions: return Color(red: 0.22, green: 0.78, blue: 0.46)
        case .updates: return Color(red: 0.16, green: 0.60, blue: 1.00)
        case .about: return Color(red: 0.95, green: 0.56, blue: 0.18)
        }
    }
}

// MARK: - Root Settings view

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var router = SettingsRouter.shared
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var volume = VolumeController.shared
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var recording = false
    @State private var accent: Color = Theme.accent
    @State private var perms: [Permission: Permissions.Status] = [:]
    @State private var permissionNote: String?
    @State private var copiedShortcutsPath = false
    @State private var clearedLocalData = false
    @State private var showAdvancedIntegrations = false

    private static let accentSwatches: [(name: String, hex: String, color: Color)] = [
        ("White", "#FFFFFF", .white),
        ("Sky", "#5AC8FA", Color(hex: "#5AC8FA") ?? .cyan),
        ("Blue", "#0A84FF", Color(hex: "#0A84FF") ?? .blue),
        ("Indigo", "#6E7BFF", Color(hex: "#6E7BFF") ?? .indigo),
        ("Purple", "#B591FF", Color(hex: "#B591FF") ?? .purple),
        ("Pink", "#FF6482", Color(hex: "#FF6482") ?? .pink),
        ("Orange", "#FF9F0A", Color(hex: "#FF9F0A") ?? .orange),
        ("Green", "#30D158", Color(hex: "#30D158") ?? .green),
    ]

    private var activePane: SettingsPane {
        SettingsPane(rawValue: router.tab) ?? .general
    }

    private var hasPermissionIssue: Bool {
        guard !perms.isEmpty else { return false }
        return !(perms[.accessibility]?.isGranted ?? true) || !(perms[.fullDiskAccess]?.isGranted ?? true)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detailCanvas
        }
        .frame(width: 740, height: 560)
        .onAppear {
            accent = Theme.accent
            launchAtLogin = LaunchAtLogin.isEnabled
            refreshPermissions()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: .notchPermissionsReset)) { _ in refreshPermissions() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // App brand header below the traffic lights
            HStack(spacing: 10) {
                Image(nsImage: BrandIcon.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)
                    .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text("KramaIsland")
                        .font(.system(size: 13.5, weight: .bold))
                    HStack(spacing: 5) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("v\(Updater.currentVersion)")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 38)
            .padding(.bottom, 16)

            VStack(spacing: 3) {
                ForEach(SettingsPane.allCases) { pane in
                    sidebarRow(pane)
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            Divider().padding(.horizontal, 12)

            HStack {
                Button {
                    NSApp.terminate(nil)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "power")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Quit KramaIsland")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(width: 204)
        .frame(maxHeight: .infinity)
        .background(SidebarBackdrop())
    }

    private func sidebarRow(_ pane: SettingsPane) -> some View {
        let selected = activePane == pane
        return Button {
            router.tab = pane.rawValue
        } label: {
            HStack(spacing: 9) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(pane.tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(pane.sidebarTitle)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? .primary : .secondary)
                Spacer()
                if pane == .permissions, hasPermissionIssue {
                    Circle().fill(Color.orange).frame(width: 7, height: 7)
                } else if pane == .updates, updater.available != nil {
                    Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                selected ? Color.primary.opacity(0.10) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail canvas

    private var detailCanvas: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(activePane.title)
                        .font(.system(size: 20, weight: .bold))
                    Text(activePane.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)

                switch activePane {
                case .general: generalPane
                case .modules: modulesPane
                case .visibility: visibilityPane
                case .permissions: permissionsPane
                case .updates: UpdatesSettingsView()
                case .about: aboutPane
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 24)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - General

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingSection("Startup") {
                SettingToggleRow(
                    symbol: "arrow.up.forward.app.fill", tint: .blue,
                    title: "Launch at login",
                    subtitle: "Start KramaIsland automatically when you sign in",
                    isOn: Binding(get: { launchAtLogin }, set: { launchAtLogin = $0; LaunchAtLogin.set($0) })
                )
                SettingDivider()
                SettingToggleRow(
                    symbol: "menubar.rectangle", tint: .indigo,
                    title: "Show menu bar icon",
                    subtitle: "Quick access to Shade, Quiet Mode, and Settings",
                    isOn: $settings.showMenuBarIcon
                )
            }

            SettingSection("Global Launcher Shortcut") {
                SettingRow(
                    symbol: "command", tint: .purple,
                    title: "Open command launcher",
                    subtitle: AXIsProcessTrusted()
                        ? "Accessibility active — keystroke is cleanly swallowed."
                        : "Observe-only mode — grant Accessibility to swallow the keystroke."
                ) {
                    HStack(spacing: 8) {
                        Text(settings.hotkeyDescription.replacingOccurrences(of: "Space", with: " Space").trimmingCharacters(in: .whitespaces))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        Button(recording ? "Press keys…" : "Change…") { recording.toggle() }
                            .controlSize(.small)
                            .background(KeyRecorder(active: $recording) { code, flags in
                                settings.hotkeyKeyCode = code
                                settings.hotkeyModifiers = Int(flags.rawValue)
                                NotificationCenter.default.post(name: .notchHotkeyChanged, object: nil)
                            })
                    }
                }
            }

            SettingSection("Window Snap & Tiling") {
                SettingToggleRow(
                    symbol: "macwindow.on.rectangle", tint: .blue,
                    title: "Global ⌃⌥ snap shortcuts",
                    subtitle: "⌃⌥ ←/→/↑/↓ halves · ⌃⌥↩ fill · ⌃⌥C center · ⌃⌥2/3/4 multi-app tile · ⌃⌥⌫ restore",
                    isOn: $settings.windowSnapShortcuts
                )
                SettingDivider()
                SettingRow(
                    symbol: "square.split.2x2", tint: .indigo,
                    title: "Window gap spacing",
                    subtitle: "Space left around and between tiled windows"
                ) {
                    Picker("", selection: $settings.windowSnapGap) {
                        Text("Flush (0 pt)").tag(0.0)
                        Text("Compact (6 pt)").tag(6.0)
                        Text("Spacious (12 pt)").tag(12.0)
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
            }

            SettingSection("Interaction & Feel") {
                SettingRow(
                    symbol: "cursorarrow.motionlines", tint: .teal,
                    title: "Hover delay",
                    subtitle: "Wait time before hovering the notch expands the island"
                ) {
                    HStack(spacing: 8) {
                        Slider(value: $settings.hoverDelay, in: 0...0.5, step: 0.01)
                            .frame(width: 130)
                        Text(settings.hoverDelay < 0.005 ? "Instant" : "\(Int((settings.hoverDelay * 1000).rounded())) ms")
                            .font(.system(size: 11.5, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                }
                SettingDivider()
                SettingToggleRow(
                    symbol: "hand.tap.fill", tint: .orange,
                    title: "Haptic feedback",
                    subtitle: "Subtle Force Touch trackpad clicks on toggles and notifications",
                    isOn: $settings.haptics
                )
                SettingDivider()
                SettingToggleRow(
                    symbol: "speaker.wave.2.fill", tint: .pink,
                    title: "Sound effects",
                    subtitle: "Play soft system sounds on interactions and alerts",
                    isOn: $settings.sounds
                )
            }

            SettingSection("Appearance") {
                SettingRow(
                    symbol: "paintpalette.fill", tint: .pink,
                    title: "Accent color",
                    subtitle: "Used for prominent buttons, rings, and highlights"
                ) {
                    HStack(spacing: 7) {
                        ForEach(Self.accentSwatches, id: \.hex) { swatch in
                            let isCurrent = settings.accentHex.uppercased() == swatch.hex
                            Button {
                                accent = swatch.color
                                settings.accentHex = swatch.hex
                            } label: {
                                Circle()
                                    .fill(swatch.color)
                                    .frame(width: 16, height: 16)
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.75))
                                    .overlay {
                                        if isCurrent {
                                            Circle()
                                                .strokeBorder(Color.accentColor, lineWidth: 2)
                                                .frame(width: 22, height: 22)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .help(swatch.name)
                        }
                        ColorPicker("", selection: $accent, supportsOpacity: false)
                            .labelsHidden()
                            .frame(width: 24)
                            .onChange(of: accent) { newValue in settings.accentHex = NSColor(newValue).hexString }
                    }
                }
                SettingDivider()
                SettingToggleRow(
                    symbol: "rectangle.on.rectangle.angled", tint: .gray,
                    title: "Translucent shade cards",
                    subtitle: "Slightly brighter glass cards inside the true-black island",
                    isOn: $settings.translucentShade
                )
                SettingDivider()
                SettingToggleRow(
                    symbol: "shadow", tint: .secondary,
                    title: "Drop shadow under open island",
                    subtitle: "Soft window-style shadow when expanded; none while collapsed",
                    isOn: $settings.islandShadow
                )
            }
        }
    }

    // MARK: - Modules

    private var modulesPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingSection("Live Activities") {
                SettingToggleRow(
                    symbol: "music.note", tint: .pink,
                    title: "Now Playing",
                    subtitle: "Spotify, Apple Music, TV, Podcasts, VLC, browsers & system feed",
                    isOn: $settings.mediaEnabled
                )
                SettingDivider()
                SettingToggleRow(
                    symbol: "bell.badge.fill", tint: .red,
                    title: "Notifications",
                    subtitle: "Dual-engine capture (Full Disk Access + Live Banners) with OTP copy & grouped shade",
                    isOn: $settings.notificationsEnabled
                )
                if settings.notificationsEnabled {
                    SettingDivider()
                    notificationEngineRow
                    SettingDivider()
                    SettingRow(
                        symbol: "eye.slash.fill", tint: .purple,
                        title: "Replace native macOS notification banners",
                        subtitle: (perms[.accessibility]?.isGranted ?? false)
                            ? "Active — closes the top-right macOS banner so only KramaIsland shows"
                            : "Closes the original macOS banner when mirrored (requires Accessibility permission)"
                    ) {
                        HStack(spacing: 8) {
                            if settings.replaceSystemNotificationBanner {
                                if perms[.accessibility]?.isGranted ?? false {
                                    trustChip("Active", tint: .green)
                                } else {
                                    Button("Allow…") { Permissions.ask(.accessibility) }
                                        .controlSize(.small)
                                }
                            }
                            Toggle("", isOn: $settings.replaceSystemNotificationBanner)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                    }
                    SettingDivider()
                    SettingRow(
                        symbol: "timer", tint: .orange,
                        title: "Banner display duration",
                        subtitle: "How long drop-in banners stay visible before collapsing (hover pauses)"
                    ) {
                        Picker("", selection: $settings.notificationBannerDuration) {
                            Text("3 seconds").tag(3.0)
                            Text("6 seconds").tag(6.0)
                            Text("9 seconds").tag(9.0)
                            Text("12 seconds").tag(12.0)
                        }
                        .labelsHidden()
                        .frame(width: 120)
                    }
                    SettingDivider()
                    SettingToggleRow(
                        symbol: "key.fill", tint: .cyan,
                        title: "Smart verification code (OTP) copy",
                        subtitle: "Automatically shows a one-click Copy pill when a 2FA code arrives",
                        isOn: $settings.notificationDetectOTP
                    )
                    SettingDivider()
                    SettingToggleRow(
                        symbol: "circle.badge.fill", tint: .red,
                        title: "Unread badge in compact notch",
                        subtitle: "Shows a subtle bell & unread count in the ears while alerts wait in the Shade",
                        isOn: $settings.notificationUnreadDot
                    )
                    SettingDivider()
                    SettingToggleRow(
                        symbol: "speaker.wave.2.fill", tint: .pink,
                        title: "Subtle alert chime",
                        subtitle: "Plays a soft pop sound when mirrored notifications drop into the island",
                        isOn: $settings.notificationSound
                    )
                    if !settings.mutedNotificationAppIDs.isEmpty {
                        SettingDivider()
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Muted Apps")
                                    .font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Button("Unmute All") { settings.mutedNotificationApps = "" }
                                    .controlSize(.small)
                            }
                            FlowLayout(spacing: 6) {
                                ForEach(Array(settings.mutedNotificationAppIDs).sorted(), id: \.self) { id in
                                    Button {
                                        settings.setNotificationAppMuted(id, muted: false)
                                    } label: {
                                        HStack(spacing: 5) {
                                            Text(AppIconCache.name(for: id))
                                                .font(.system(size: 10.5, weight: .medium))
                                            Image(systemName: "xmark")
                                                .font(.system(size: 8.5, weight: .bold))
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.primary.opacity(0.08), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .help("Unmute \(AppIconCache.name(for: id))")
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }
                SettingDivider()
                SettingToggleRow(
                    symbol: "speaker.wave.3.fill", tint: .blue,
                    title: "Volume HUD",
                    subtitle: "Interactive Dynamic Island volume bar with smooth 120 fps scrubbing & mute",
                    isOn: $settings.volumeHUDEnabled
                )
                if settings.volumeHUDEnabled {
                    SettingDivider()
                    SettingRow(
                        symbol: "eye.slash.fill", tint: .cyan,
                        title: "Replace native macOS volume popup",
                        subtitle: volume.isInterceptingKeys
                            ? "Active — hardware volume keys show KramaIsland instead of the macOS OSD"
                            : "Hides the default macOS volume overlay (requires Accessibility permission)"
                    ) {
                        HStack(spacing: 8) {
                            if settings.replaceSystemVolumeHUD {
                                if volume.isInterceptingKeys {
                                    trustChip("Active", tint: .green)
                                } else {
                                    Button("Allow…") { Permissions.ask(.accessibility) }
                                        .controlSize(.small)
                                }
                            }
                            Toggle("", isOn: $settings.replaceSystemVolumeHUD)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                    }
                    SettingDivider()
                    SettingToggleRow(
                        symbol: "waveform", tint: .teal,
                        title: "Volume key feedback click",
                        subtitle: "Play the soft macOS pop sound on volume steps (hold ⇧ to flip temporarily)",
                        isOn: $settings.volumeFeedbackSound
                    )
                }
                SettingDivider()
                SettingToggleRow(
                    symbol: "battery.100percent.bolt", tint: .green,
                    title: "Battery & Charger",
                    subtitle: "Plug/unplug HUD and low-battery warnings (20%, 10%, 5%)",
                    isOn: $settings.batteryAlertsEnabled
                )
                SettingDivider()
                SettingToggleRow(
                    symbol: "airpodspro", tint: .cyan,
                    title: "Bluetooth & AirPods",
                    subtitle: "Connect alerts with left, right, and case battery levels",
                    isOn: $settings.bluetoothEnabled
                )
                SettingDivider()
                SettingToggleRow(
                    symbol: "arrow.down.circle.fill", tint: .indigo,
                    title: "Downloads Progress",
                    subtitle: "Live progress ring for active downloads in ~/Downloads",
                    isOn: $settings.downloadsEnabled
                )
                SettingDivider()
                SettingToggleRow(
                    symbol: "waveform.badge.mic", tint: .orange,
                    title: "Privacy & Focus Indicators",
                    subtitle: "Compact badges when microphone, camera, or Focus is active",
                    isOn: $settings.indicatorsEnabled
                )
            }

            SettingSection("Shade Widgets") {
                SettingToggleRow(
                    symbol: "calendar", tint: .red,
                    title: "Next Calendar Event",
                    subtitle: "Upcoming meeting with one-click Join for Zoom, Meet & Teams",
                    isOn: $settings.calendarEnabled
                )
                SettingDivider()
                SettingToggleRow(
                    symbol: "timer", tint: .orange,
                    title: "Timer & Pomodoro",
                    subtitle: "Quick countdown presets with progress ring and completion chime",
                    isOn: $settings.timerEnabled
                )
                SettingDivider()
                SettingToggleRow(
                    symbol: "doc.on.clipboard.fill", tint: .teal,
                    title: "Clipboard History",
                    subtitle: "Shows session copies with source app; automatically clears on shutdown",
                    isOn: $settings.clipboardEnabled
                )
                SettingDivider()
                SettingToggleRow(
                    symbol: "tray.full.fill", tint: .blue,
                    title: "File Shelf",
                    subtitle: "Drag files onto the notch to park, drag out, or AirDrop",
                    isOn: $settings.shelfEnabled
                )
                SettingDivider()
                SettingToggleRow(
                    symbol: "switch.2", tint: .purple,
                    title: "Quick Toggles",
                    subtitle: "Dark Mode, Keep Awake, Wi-Fi, Camera Mirror, Quiet & Focus",
                    isOn: $settings.quickTogglesEnabled
                )
                SettingDivider()
                SettingToggleRow(
                    symbol: "macwindow.on.rectangle", tint: .blue,
                    title: "Window Snap & Tiling",
                    subtitle: "Windows 11-style snap layouts and 2/3/4-app multi-platform tiling",
                    isOn: $settings.windowSnapEnabled
                )
            }
        }
        .onChange(of: settings.mediaEnabled) { _ in NotificationCenter.default.post(name: .notchModulesChanged, object: nil) }
        .onChange(of: settings.notificationsEnabled) { _ in NotificationCenter.default.post(name: .notchModulesChanged, object: nil) }
        .onChange(of: settings.clipboardEnabled) { _ in NotificationCenter.default.post(name: .notchModulesChanged, object: nil) }
        .onChange(of: settings.downloadsEnabled) { _ in NotificationCenter.default.post(name: .notchModulesChanged, object: nil) }
        .onChange(of: settings.bluetoothEnabled) { _ in NotificationCenter.default.post(name: .notchModulesChanged, object: nil) }
        .onChange(of: settings.batteryAlertsEnabled) { _ in NotificationCenter.default.post(name: .notchModulesChanged, object: nil) }
        .onChange(of: settings.calendarEnabled) { _ in NotificationCenter.default.post(name: .notchModulesChanged, object: nil) }
        .onChange(of: settings.indicatorsEnabled) { _ in NotificationCenter.default.post(name: .notchModulesChanged, object: nil) }
    }

    // MARK: - Visibility

    private var visibilityPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingSection("Quiet Mode") {
                SettingToggleRow(
                    symbol: "bell.slash.fill", tint: .pink,
                    title: "Quiet Mode",
                    subtitle: settings.quietManualOn && settings.quietUntil > 0
                        ? "Active until \(Date(timeIntervalSince1970: settings.quietUntil).formatted(date: .omitted, time: .shortened))"
                        : "Suppress HUDs and notification banners; hover & click still open",
                    isOn: Binding(get: { settings.quietManualOn }, set: { settings.setQuiet($0) })
                )
                SettingDivider()
                SettingToggleRow(
                    symbol: "moon.fill", tint: .purple,
                    title: "Follow macOS Focus",
                    subtitle: "Automatically turn on Quiet Mode whenever any Focus is active",
                    isOn: $settings.quietWithFocus
                )
                SettingDivider()
                SettingToggleRow(
                    symbol: "eye.slash.fill", tint: .gray,
                    title: "Hide compact ears while quiet",
                    subtitle: "Keep the notch completely bare with no artwork or indicators",
                    isOn: $settings.quietHidesEars
                )
            }

            SettingSection("Breakthrough Exceptions") {
                SettingToggleRow(
                    symbol: "timer", tint: .orange,
                    title: "Timer finished",
                    subtitle: "Still show the alert when a countdown completes",
                    isOn: $settings.quietAllowTimer
                )
                SettingDivider()
                SettingToggleRow(
                    symbol: "battery.25percent", tint: .red,
                    title: "Low battery warnings",
                    subtitle: "Still alert at 20%, 10%, and 5% battery",
                    isOn: $settings.quietAllowLowBattery
                )
                SettingDivider()
                SettingToggleRow(
                    symbol: "sparkles", tint: .blue,
                    title: "Shortcuts activities",
                    subtitle: "Allow custom activities written to activity.json",
                    isOn: $settings.quietAllowCustom
                )
            }

            SettingSection("Auto-Hide & Displays") {
                SettingToggleRow(
                    symbol: "arrow.up.left.and.arrow.down.right", tint: .indigo,
                    title: "Hide in full-screen apps",
                    subtitle: "Automatically hide the island over full-screen windows",
                    isOn: $settings.hideInFullscreen
                )
                SettingDivider()
                SettingRow(
                    symbol: "app.dashed", tint: .secondary,
                    title: "Hidden apps",
                    subtitle: "Comma-separated bundle identifiers (e.g. com.apple.keynote)"
                ) {
                    TextField("com.apple.keynote, com.company.game", text: $settings.hiddenApps)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 210)
                }
                SettingDivider()
                SettingRow(
                    symbol: "display", tint: .blue,
                    title: "Show island on",
                    subtitle: displayStatusSummary
                ) {
                    Picker("", selection: $settings.displayPreference) {
                        Text("Automatic (Notch)").tag("auto")
                        Text("Main Display").tag("main")
                        ForEach(NSScreen.screens.map(\.localizedName), id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }
            }
        }
    }

    private var displayStatusSummary: String {
        let g = NotchGeometry.current
        let w = Int(g.screen.frame.width), h = Int(g.screen.frame.height)
        return "\(g.screen.localizedName) (\(w)×\(h) · \(g.hasNotch ? "Notch" : "Standard"))"
    }

    // MARK: - Privacy & Permissions

    private var permissionsPane: some View {
        let grantedCore = Permission.coreCases.filter { perms[$0]?.isGranted == true }.count
        let allCoreReady = grantedCore == Permission.coreCases.count

        return VStack(alignment: .leading, spacing: 16) {
            // Privacy & readiness hero card
            HStack(spacing: 14) {
                Image(systemName: allCoreReady ? "checkmark.shield.fill" : "lock.shield.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        (allCoreReady
                         ? Color(red: 0.20, green: 0.78, blue: 0.45)
                         : Color(red: 0.96, green: 0.62, blue: 0.14)).gradient,
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text(allCoreReady
                         ? "All core permissions active"
                         : "\(grantedCore) of \(Permission.coreCases.count) core permissions active")
                        .font(.system(size: 13.5, weight: .bold))
                    Text("All notifications, media, and clipboard data stay strictly on your Mac.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        trustChip("On-Device Only", tint: .green)
                        trustChip("Zero Analytics", tint: .blue)
                        trustChip(settings.updatesAutoCheck ? "Updates Check Only" : "Strict Offline",
                                  tint: settings.updatesAutoCheck ? .indigo : .green)
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 6)
                Button("System Privacy…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))

            // Real on-device user privacy controls
            SettingSection("User Privacy Controls") {
                SettingToggleRow(
                    symbol: "eye.slash.fill", tint: .purple,
                    title: "Hide notification message previews",
                    subtitle: "Masks sensitive bodies & OTP codes in banners, hover, and shade while keeping app alerts visible",
                    isOn: $settings.privacyHideNotificationBody
                )
                SettingDivider()
                SettingRow(
                    symbol: "clock.arrow.circlepath", tint: .teal,
                    title: "Auto-clear clipboard history",
                    subtitle: "Password-manager secrets are always skipped; optionally expire older copies sooner"
                ) {
                    Picker("", selection: $settings.clipboardAutoClearMinutes) {
                        Text("Until shutdown").tag(0)
                        Text("After 15 min").tag(15)
                        Text("After 1 hour").tag(60)
                    }
                    .labelsHidden()
                    .frame(width: 135)
                }
                SettingDivider()
                SettingToggleRow(
                    symbol: "power", tint: .orange,
                    title: "Auto-clear clipboard on shutdown",
                    subtitle: "Shows everything copied during this Mac session and wipes history + pasteboard on shutdown or restart",
                    isOn: $settings.clearClipboardOnShutdown
                )
                SettingDivider()
                SettingToggleRow(
                    symbol: "wifi.slash", tint: .green,
                    title: "Strict offline mode",
                    subtitle: "Disables daily GitHub update checks so KramaIsland makes zero network requests",
                    isOn: Binding(
                        get: { !settings.updatesAutoCheck },
                        set: { settings.updatesAutoCheck = !$0 }
                    )
                )
            }

            // Core macOS TCC grants
            SettingSection("Core macOS Permissions") {
                ForEach(Array(Permission.coreCases.enumerated()), id: \.element.id) { idx, p in
                    if idx > 0 { SettingDivider() }
                    permissionRow(p)
                }
                if let permissionNote {
                    SettingDivider()
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill").foregroundStyle(.orange)
                        Text(permissionNote)
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }

            if !(perms[.fullDiskAccess]?.isGranted ?? false) {
                let inApplications = Bundle.main.bundleURL.path.hasPrefix("/Applications/")
                HStack(spacing: 12) {
                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 28, height: 28)
                        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Finish Notification Setup")
                            .font(.system(size: 12, weight: .semibold))
                        Text(inApplications
                             ? "Click + in Full Disk Access, choose KramaIsland from Applications, toggle it on, then relaunch."
                             : "Click + in Full Disk Access and choose KramaIsland (or click Reveal App and drag it into the list), then relaunch.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 6) {
                        Button("Reveal App") {
                            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                        }
                        .controlSize(.small)
                        Button("Open Pane") { Permissions.ask(.fullDiskAccess) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        Button("Relaunch") { QuickSystem.relaunch() }
                            .controlSize(.small)
                    }
                }
                .padding(12)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.orange.opacity(0.24), lineWidth: 1))
            }

            // On-demand hardware & app control permissions
            SettingSection("Hardware & App Control") {
                ForEach(Array(Permission.hardwareCases.enumerated()), id: \.element.id) { idx, p in
                    if idx > 0 { SettingDivider() }
                    permissionRow(p)
                }
                SettingDivider()
                HStack(spacing: 12) {
                    Image(systemName: "apple.terminal.on.rectangle")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.blue)
                        .frame(width: 28, height: 28)
                        .background(Color.blue.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Automation").font(.system(size: 12.5, weight: .semibold))
                            Text("Per-App")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.14), in: Capsule())
                        }
                        Text("Requested per app when controlling Music, Spotify, VLC, browsers, or Dark Mode.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Manage") { PrivacyPane.open(PrivacyPane.automation) }
                        .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            // Collapsible browser JS & Shortcuts details so the main pane stays clean
            VStack(alignment: .leading, spacing: 0) {
                DisclosureGroup(isExpanded: $showAdvancedIntegrations) {
                    VStack(alignment: .leading, spacing: 0) {
                        Divider().padding(.vertical, 8)
                        SettingRow(
                            symbol: "globe", tint: .blue,
                            title: "Chromium Browsers (Chrome, Brave, Edge, Arc, Vivaldi, Opera)",
                            subtitle: "View ▸ Developer ▸ Allow JavaScript from Apple Events (once per browser)"
                        ) { EmptyView() }
                        SettingDivider()
                        SettingRow(
                            symbol: "safari.fill", tint: .cyan,
                            title: "Safari",
                            subtitle: "Settings ▸ Advanced ▸ Developer features, then Develop ▸ Allow JavaScript from Apple Events"
                        ) { EmptyView() }
                        SettingDivider()
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Shortcuts Custom Activity Path")
                                        .font(.system(size: 12, weight: .semibold))
                                    Text(CustomActivityWatcher.fileURL.path)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                Button(copiedShortcutsPath ? "Copied" : "Copy Path") {
                                    let pb = NSPasteboard.general
                                    pb.clearContents()
                                    pb.setString(CustomActivityWatcher.fileURL.path, forType: .string)
                                    copiedShortcutsPath = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedShortcutsPath = false }
                                }
                                .controlSize(.small)
                            }
                            Text(#"{"title":"Build done","subtitle":"main · 42s","symbol":"hammer.fill","progress":1,"seconds":5}"#)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .textSelection(.enabled)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Browser Tab Controls & Shortcuts Setup")
                                .font(.system(size: 12.5, weight: .semibold))
                            Text("Optional JavaScript bridge instructions and activity.json path")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))

            // Data hygiene & permission reset
            SettingSection("Data Hygiene & Reset") {
                SettingRow(
                    symbol: "trash.fill", tint: .orange,
                    title: "Clear local history & cache",
                    subtitle: "Wipes clipboard history, shelf items, recent alerts, and launcher recents on-device"
                ) {
                    Button(clearedLocalData ? "Cleared ✓" : "Clear Data") {
                        NotificationCenter.default.post(name: .notchClearLocalData, object: nil)
                        clearedLocalData = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { clearedLocalData = false }
                    }
                    .controlSize(.small)
                }
                SettingDivider()
                SettingRow(
                    symbol: "arrow.counterclockwise", tint: .red,
                    title: "Reset all macOS permissions",
                    subtitle: "Clears stale TCC grants after signature changes and relaunches KramaIsland"
                ) {
                    Button("Reset All…") { confirmResetAll() }
                        .controlSize(.small)
                }
            }
        }
    }

    private var notificationEngineRow: some View {
        let fdaOK = perms[.fullDiskAccess]?.isGranted ?? false
        let axOK = perms[.accessibility]?.isGranted ?? false
        let statusLabel: String
        let statusTint: Color
        let detail: String
        switch (fdaOK, axOK) {
        case (true, true):
            statusLabel = "Full + Live"; statusTint = .green
            detail = "Instant live banners plus full 24h Notification Center history"
        case (true, false):
            statusLabel = "Full History"; statusTint = .green
            detail = "Notification Center database active (grant Accessibility for instant banners)"
        case (false, true):
            statusLabel = "Live Active"; statusTint = .cyan
            detail = "Capturing all live banners instantly (add Full Disk Access for 24h history)"
        case (false, false):
            statusLabel = "Setup Needed"; statusTint = .orange
            detail = "Grant Accessibility or Full Disk Access under Privacy to mirror notifications"
        }
        return SettingRow(
            symbol: "antenna.radiowaves.left.and.right", tint: statusTint,
            title: "Capture Engine",
            subtitle: detail
        ) {
            HStack(spacing: 8) {
                trustChip(statusLabel, tint: statusTint)
                Button("Test Banner") {
                    IslandState.shared?.sendTestNotification()
                }
                .controlSize(.small)
                .help("Preview KramaIsland's notification banner right under the notch")
            }
        }
    }

    private func trustChip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(tint.opacity(0.13), in: Capsule())
    }

    // MARK: - About

    private var aboutPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 12) {
                Image(nsImage: BrandIcon.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 84, height: 84)
                    .shadow(color: .black.opacity(0.30), radius: 12, y: 5)
                VStack(spacing: 4) {
                    Text("KramaIsland")
                        .font(.system(size: 20, weight: .bold))
                    Text("Created by Mao Seavik")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") (Build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "source"))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }
                Text(Bundle.main.bundleIdentifier ?? "com.kramaisland.app")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: Capsule())

                HStack(spacing: 8) {
                    Button("GitHub Repository") {
                        if let u = URL(string: "https://github.com/\(Updater.repo)") { NSWorkspace.shared.open(u) }
                    }
                    .controlSize(.small)
                    Button("Releases") { updater.openReleasePage() }
                        .controlSize(.small)
                    Button("Report Issue") {
                        if let u = URL(string: "https://github.com/\(Updater.repo)/issues") { NSWorkspace.shared.open(u) }
                    }
                    .controlSize(.small)
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))

            SettingSection("Author & Build") {
                SettingRow(
                    symbol: "person.crop.circle.fill", tint: .indigo,
                    title: "Mao Seavik",
                    subtitle: "Creator and maintainer of KramaIsland"
                ) { EmptyView() }
                SettingDivider()
                SettingRow(
                    symbol: "checkmark.seal.fill", tint: .green,
                    title: "Signing identity",
                    subtitle: Permissions.identitySummary
                ) { EmptyView() }
                if !Permissions.isBundled {
                    SettingDivider()
                    SettingRow(
                        symbol: "terminal.fill", tint: .orange,
                        title: "Development build",
                        subtitle: "Running from source: macOS keys grants to the binary path."
                    ) { EmptyView() }
                }
            }

            Text("MIT License · © 2026 Mao Seavik")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 4)
        }
    }

    // MARK: - Permission helpers

    private func refreshPermissions() {
        var next: [Permission: Permissions.Status] = [:]
        for p in Permission.allCases { next[p] = Permissions.status(p) }
        if next != perms { perms = next }
    }

    private func permissionRow(_ p: Permission) -> some View {
        let s = perms[p] ?? Permissions.Status(grant: .unknown, stale: false)
        let badgeText: String
        let badgeColor: Color
        let iconTint: Color

        switch (s.grant, s.stale) {
        case (.granted, _):
            badgeText = "Allowed"; badgeColor = .green; iconTint = .green
        case (.denied, true):
            badgeText = "Needs Reset"; badgeColor = .orange; iconTint = .orange
        case (.denied, false):
            badgeText = "Off"; badgeColor = .red; iconTint = .red
        case (.notAsked, _):
            badgeText = "Not Asked"; badgeColor = .secondary; iconTint = .blue
        case (.unknown, _):
            badgeText = "Pending"; badgeColor = .secondary; iconTint = .secondary
        }

        return HStack(spacing: 12) {
            Image(systemName: p.symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(iconTint)
                .frame(width: 28, height: 28)
                .background(iconTint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(p.title).font(.system(size: 12.5, weight: .semibold))
                    Text(badgeText)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(badgeColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(badgeColor.opacity(0.14), in: Capsule())
                }
                Text(s.stale
                     ? "Granted to an earlier build. Click Reset, then allow again."
                     : p.purpose)
                    .font(.system(size: 11))
                    .foregroundStyle(s.stale ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if s.isGranted {
                Button("Manage") { PrivacyPane.open(p.pane) }
                    .controlSize(.small)
                    .help("Review or revoke \(p.title) in System Settings")
            } else {
                HStack(spacing: 6) {
                    Button(p.hasPrompt ? "Allow…" : "Open Settings") { Permissions.ask(p) }
                        .controlSize(.small)
                    if s.grant == .denied {
                        Button("Reset…") { repair(p) }
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func repair(_ p: Permission) {
        permissionNote = nil
        Permissions.repair(p) { ok, message in
            if !ok {
                permissionNote = "Reset failed\(message.isEmpty ? "" : " (\(message))"). Remove KramaIsland from \(p.title) with − and add it again with +."
            } else if p == .fullDiskAccess {
                permissionNote = "Entry removed. In Full Disk Access click +, select KramaIsland from Applications, enable it and relaunch."
            }
            refreshPermissions()
        }
    }

    private func confirmResetAll() {
        let alert = NSAlert()
        alert.messageText = "Reset all of KramaIsland's permissions?"
        alert.informativeText = "macOS forgets every grant KramaIsland has: Accessibility, Full Disk Access, Calendar, Automation, Bluetooth and Camera. It asks again on next use; Full Disk Access is added again by hand. KramaIsland relaunches afterwards."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset and Relaunch")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Permissions.reset(nil) { ok, message in
            if ok { QuickSystem.relaunch() } else { permissionNote = "Reset failed\(message.isEmpty ? "" : " (\(message))")." }
        }
    }
}

// MARK: - Shared modern Settings building blocks

struct SettingSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                content()
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        }
    }
}

struct SettingDivider: View {
    var body: some View {
        Divider().padding(.leading, 54)
    }
}

struct SettingRow<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1.5) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct SettingToggleRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(symbol: symbol, tint: tint, title: title, subtitle: subtitle) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

private struct SidebarBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Invisible view that grabs the next key press while `active` is true.
struct KeyRecorder: NSViewRepresentable {
    @Binding var active: Bool
    var onKey: (Int, NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        if active, context.coordinator.monitor == nil {
            context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    .intersection([.command, .option, .control, .shift])
                if event.keyCode == 53 && flags.isEmpty {   // Esc cancels
                    DispatchQueue.main.async { active = false }
                    return nil
                }
                guard !flags.isEmpty || event.keyCode >= 96 else { return event }   // need a modifier unless F-key
                onKey(Int(event.keyCode), flags)
                DispatchQueue.main.async { active = false }
                return nil
            }
        } else if !active, let m = context.coordinator.monitor {
            NSEvent.removeMonitor(m)
            context.coordinator.monitor = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var monitor: Any? }
}
