import AppKit
import SwiftUI
import KramaIslandInfoPlist

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panels: NotchPanelManager!
    private let state = IslandState()
    private let hotkey = HotkeyManager()
    private let menuBar = MenuBarController()
    private let visibility = VisibilityMonitor()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var accessibilityPoll: Timer?
    private var lastSettingsSnapshot: SettingsSnapshot?

    private struct SettingsSnapshot: Equatable {
        let showMenuBarIcon: Bool
        let displayPreference: String
        let islandWidth: Double
        let islandHeight: Double
        let hideInFullscreen: Bool
        let hideInFullscreenMode: String
        let hiddenApps: String
        let volumeHUDEnabled: Bool
        let replaceSystemVolumeHUD: Bool

        static var current: SettingsSnapshot {
            let s = AppSettings.shared
            return SettingsSnapshot(
                showMenuBarIcon: s.showMenuBarIcon,
                displayPreference: s.displayPreference,
                islandWidth: s.islandWidth,
                islandHeight: s.islandHeight,
                hideInFullscreen: s.hideInFullscreen,
                hideInFullscreenMode: s.hideInFullscreenMode,
                hiddenApps: s.hiddenApps,
                volumeHUDEnabled: s.volumeHUDEnabled,
                replaceSystemVolumeHUD: s.replaceSystemVolumeHUD
            )
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = KramaIslandInfoPlistMarker()   // keeps the embedded Info.plist linked in
        NSApp.applicationIconImage = BrandIcon.image

        panels = NotchPanelManager(state: state)
        panels.show()
        state.start()
        AirDropManager.shared.warmUp()   // pre-warms AirDrop XPC off the critical path so first drop is instant
        Updater.shared.startSchedule()   // launch + daily check against GitHub Releases (Settings ▸ Updates)

        // Menu bar icon
        menuBar.openShade = { [weak self] in self?.state.openShade() }
        menuBar.openLauncher = { [weak self] in self?.state.toggleLauncher() }
        menuBar.openSettings = { SettingsWindowController.shared.show() }
        menuBar.setVisible(AppSettings.shared.showMenuBarIcon)

        // Hotkey: CGEvent tap (swallows the key) when Accessibility allows, NSEvent monitors otherwise.
        hotkey.onTrigger = { [weak self] in self?.state.toggleLauncher() }
        hotkey.extraHandler = { code, flags in WindowManager.shared.handleShortcut(keyCode: code, flags: flags) }
        installHotkey()
        state.setAccessibilityGranted(AXIsProcessTrusted())
        NotificationCenter.default.addObserver(forName: .notchHotkeyChanged, object: nil, queue: .main) { [weak self] _ in
            self?.installHotkey()
        }
        // A grant made (or lost) while running must be picked up without a relaunch: macOS announces
        // changes to the Accessibility list, and a slow poll covers the cases it does not.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.rearmHotkeyIfNeeded() }
        }
        accessibilityPoll = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.rearmHotkeyIfNeeded()
        }
        Permissions.calendarRequest = { [weak self] in self?.state.calendar.requestAccess() }

        // Hide per-display over full-screen videos / full-screen apps / listed apps.
        visibility.onHiddenDisplaysChange = { [weak self] hiddenIDs in
            self?.panels.setHiddenDisplays(hiddenIDs)
        }
        visibility.start()

        // Settings that take effect live — diffed so unrelated macOS AppKit / NSOpenPanel / AirDrop
        // UserDefaults writes never trigger unnecessary display syncs or fullscreen checks.
        lastSettingsSnapshot = .current
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let prev = self.lastSettingsSnapshot
            let curr = SettingsSnapshot.current
            guard prev != curr else { return }
            self.lastSettingsSnapshot = curr

            if prev?.showMenuBarIcon != curr.showMenuBarIcon {
                self.menuBar.setVisible(curr.showMenuBarIcon)
            }
            if prev?.displayPreference != curr.displayPreference
                || prev?.islandWidth != curr.islandWidth
                || prev?.islandHeight != curr.islandHeight {
                self.panels.syncDisplays()
            }
            if prev?.hideInFullscreen != curr.hideInFullscreen
                || prev?.hideInFullscreenMode != curr.hideInFullscreenMode
                || prev?.hiddenApps != curr.hiddenApps
                || prev?.displayPreference != curr.displayPreference {
                self.visibility.evaluate()
            }
            if prev?.volumeHUDEnabled != curr.volumeHUDEnabled
                || prev?.replaceSystemVolumeHUD != curr.replaceSystemVolumeHUD {
                VolumeController.shared.syncEventTap()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.panels.syncDisplays()
            self?.visibility.evaluate()
        }

        // KRAMAISLAND_PREVIEW=expanded|shade|launcher|banner|activity|settings opens the island (or the
        // Settings window, on the KRAMAISLAND_SETTINGS_TAB tab) for screenshots and layout work.
        // KRAMAISLAND_DEMO=1 swaps the live sources for sample data first (see IslandState.seedDemo);
        // KRAMAISLAND_QUERY pre-fills the launcher.
        let env = ProcessInfo.processInfo.environment
        let demo = env["KRAMAISLAND_DEMO"] == "1"
        if !demo, env["KRAMAISLAND_PREVIEW"] == nil {
            // After an update, grants that belong to the previous build are cleared so System
            // Settings stops showing switches that do nothing, and Accessibility is asked for again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                Permissions.repairAfterLaunchIfNeeded()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    Permissions.registerForFullDiskAccess()
                }
            }
        }
        if demo {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.state.seedDemo() }
        }
        if let preview = env["KRAMAISLAND_PREVIEW"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + (demo ? 2.2 : 1.5)) { [weak self] in
                guard let self else { return }
                switch preview {
                case "expanded": self.state.setHovering(true)
                case "shade": self.state.toggleShade()
                case "launcher":
                    self.state.toggleLauncher()
                    if let q = env["KRAMAISLAND_QUERY"] {
                        self.state.query = q
                        // Focusing the field selects its text; park the caret at the end instead.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            if let tv = NSApp.keyWindow?.firstResponder as? NSTextView {
                                tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
                            }
                        }
                    }
                case "banner": self.state.demoBanner()
                case "activity": self.state.demoActivity()
                case "volume": self.state.volume.demoHUD()
                case "settings": SettingsWindowController.shared.show()
                default: break
                }
            }
        }
    }

    /// The CGEvent tap needs Accessibility. Re-run the install when the grant appears (tap replaces
    /// the observe-only monitors) or disappears (macOS disables the tap; fall back to monitors).
    private func rearmHotkeyIfNeeded() {
        let trusted = AXIsProcessTrusted()
        if hotkey.isActive != trusted { installHotkey() }
        VolumeController.shared.rearmTapIfNeeded()
        state.notificationWatcher.refreshLiveObserver()
        state.setAccessibilityGranted(trusted)
    }

    private func installHotkey() {
        let settings = AppSettings.shared
        hotkey.configure(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyFlags)
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }

        if hotkey.start() { return }

        // Fallback: observe only (can't swallow). The global monitor still needs Accessibility to
        // see keys while another app is frontmost; the local one covers when we're frontmost.
        let code = UInt16(settings.hotkeyKeyCode)
        let flags = settings.hotkeyFlags.intersection([.command, .option, .control, .shift])
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard event.keyCode == code,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]) == flags
            else { return }
            self?.state.toggleLauncher()
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event)
            return event
        }
    }
}
