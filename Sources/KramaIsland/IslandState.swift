import AppKit
import Combine
import SwiftUI

struct AppEntry: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var icon: NSImage { AppIconCache.fileIcon(for: url.path) }
}

/// Notifications from one app, newest first, for the grouped shade.
struct NotificationGroup: Identifiable {
    let bundleID: String
    let appName: String
    let notes: [NotchNotification]
    var id: String { bundleID }
    var icon: NSImage { AppIconCache.icon(for: bundleID, appName: appName) }
}

final class IslandState: ObservableObject {
    static weak var shared: IslandState?

    // Inputs
    @Published var isExpanded = false { didSet { hoverChanged() } }
    @Published var isLauncherOpen = false { didSet { refreshLayout() } }
    @Published var isShadeOpen = false { didSet { refreshLayout() } }
    @Published var isDragTargeted = false { didSet { refreshLayout() } }
    @Published var query = "" { didSet { launcher.searchFiles(query) } }
    @Published private(set) var apps: [AppEntry] = []

    // Media, notifications, activities
    @Published private(set) var media: NowPlaying? { didSet { refreshLayout() } }
    @Published private(set) var banner: NotchNotification? { didSet { refreshLayout() } }
    @Published private(set) var bannerQueueCount = 0
    @Published private(set) var isBannerHovered = false
    @Published private(set) var latest: NotchNotification? { didSet { refreshLayout() } }
    @Published private(set) var recent: [NotchNotification] = [] { didSet { refreshLayout() } }
    @Published private(set) var dismissed: Set<String> = [] { didSet { refreshLayout() } }
    @Published var selectedNotificationCategory: NotchNotification.Category? = nil
    @Published private(set) var hint: IslandHint? { didSet { refreshLayout() } }
    @Published private(set) var activity: LiveActivity? { didSet { refreshLayout() } }
    @Published private(set) var stickyActivity: LiveActivity? { didSet { refreshLayout() } }
    @Published private(set) var volumeHUDVisible = false { didSet { refreshLayout() } }
    @Published private(set) var timerActive = false { didSet { refreshLayout() } }
    @Published private(set) var indicatorsOn = false { didSet { refreshLayout() } }
    /// Quiet Mode in effect: switched on by hand (optionally for an hour) or following a macOS
    /// Focus. Nothing pops out of the notch (no HUDs, no banners, by default no ears either);
    /// hover, click and the hotkey still open the island, and notifications still collect in the
    /// shade. Settings ▸ Visibility picks the few activities that may break through.
    @Published private(set) var isQuiet = false { didSet { refreshLayout() } }
    @Published var showMirror = false
    @Published var showAllClipboard = false
    /// Kept true while the user is live-previewing Dynamic Island dimensions from Settings.
    @Published var isSizePreviewActive = false
    /// True while directly dragging the Shade's corner resize handle.
    var isResizingIsland = false

    /// Derived shape of the island; the view and the panel both read this.
    @Published private(set) var layout = IslandLayout()
    /// Cached physical notch geometry; updated when screens change (avoids querying NSScreen in body).
    @Published var geometry: NotchGeometry = .current
    /// Live rendered size of the black island surface (non-Published so hit-test updates never re-render).
    var renderedSurfaceSize: CGSize = .zero
    var onSurfaceSizeChanged: (() -> Void)?

    // Modules
    let settings = AppSettings.shared
    let mediaController = MediaController()
    let volume = VolumeController.shared
    let notificationWatcher = NotificationWatcher()
    let activities = ActivityCenter.shared
    let timer = TimerEngine()
    let calendar = CalendarModule()
    let clipboard = ClipboardHistory()
    let shelf = ShelfStore()
    let status = SystemStatus()
    let launcher = LauncherEngine()
    let caffeine = Caffeine.shared
    let windowManager = WindowManager.shared
    private let battery = BatteryWatcher()
    private let bluetooth = BluetoothWatcher()
    private let downloads = DownloadsWatcher()
    private let custom = CustomActivityWatcher()

    private var bannerTimer: DispatchWorkItem?
    private var bannerQueue: [NotchNotification] = []
    private var testSampleIndex = 0
    private var hoverWork: DispatchWorkItem?
    private var quietExpiry: DispatchWorkItem?
    private var notificationProblem: IslandHint?
    private var accessibilityProblem: IslandHint?
    private var dismissedHints: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "dismissedHints") ?? [])
    private var sessionDismissedHints: Set<String> = []
    private var cancellables = Set<AnyCancellable>()
    private var running: Set<String> = []

    static let recentLifetime: TimeInterval = 600

    init() {
        Self.shared = self
        loadApps()
        bind()
        launcher.actions = quickActions()
        launcher.clipboardItems = { [weak self] in self?.clipboard.items ?? [] }
    }

    func start() {
        applyModuleSettings()
        volume.start()      // CoreAudio listeners + hardware volume-key interceptor
        status.start()      // event-driven and cheap; the UI gates on the setting
        custom.start()
    }

    // MARK: - Wiring

    private func bind() {
        mediaController.$nowPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] np in
                guard let self else { return }
                self.media = self.settings.mediaEnabled ? np : nil
            }
            .store(in: &cancellables)
        mediaController.$problem
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.updateHint(mediaProblem: $0) }
            .store(in: &cancellables)
        volume.$isHUDVisible
            .receive(on: DispatchQueue.main)
            .sink { [weak self] visible in
                guard let self else { return }
                let show = visible && self.settings.volumeHUDEnabled
                if self.volumeHUDVisible != show { self.volumeHUDVisible = show }
            }
            .store(in: &cancellables)

        notificationWatcher.onNotification = { [weak self] in self?.present($0) }
        notificationWatcher.onHistory = { [weak self] in self?.loadHistory($0) }
        notificationWatcher.shouldReplaceSystemBanner = { [weak self] in
            guard let self else { return false }
            return self.settings.notificationsEnabled
                && self.settings.replaceSystemNotificationBanner
                && !self.isQuiet
                && !self.volume.isIslandHiddenByPolicy
        }
        notificationWatcher.onStatus = { [weak self] problem in
            guard let self else { return }
            self.notificationProblem = problem
            self.updateHint(mediaProblem: self.mediaController.problem)
        }

        activities.$current
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.activity = $0 }
            .store(in: &cancellables)
        activities.$sticky
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.stickyActivity = $0 }
            .store(in: &cancellables)

        timer.$total
            .receive(on: DispatchQueue.main)
            .sink { [weak self] total in self?.timerActive = total > 0 }
            .store(in: &cancellables)
        timer.onFinished = { [weak self] in
            self?.activities.show(LiveActivity(id: "timer.done", kind: .timer, symbol: "timer",
                                               title: "Timer finished", subtitle: "", progress: nil,
                                               tint: UI.timer, duration: 8))
        }

        Publishers.CombineLatest3(status.$micInUse, status.$cameraInUse, status.$focusName)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mic, cam, focus in
                guard let self else { return }
                self.indicatorsOn = self.settings.indicatorsEnabled && (mic || cam || focus != nil)
            }
            .store(in: &cancellables)

        activities.allows = { [weak self] in self?.allowsWhileQuiet($0) ?? true }
        status.$focusName
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshQuiet() }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshQuiet()
            self?.refreshLayout()
        }
        refreshQuiet()

        battery.onChange = { [weak self] in self?.status.updateBattery($0) }
        battery.onEvent = { [weak self] in self?.show($0, when: \.batteryAlertsEnabled) }
        bluetooth.onEvent = { [weak self] in self?.show($0, when: \.bluetoothEnabled) }
        downloads.onEvent = { [weak self] in self?.show($0, when: \.downloadsEnabled) }
        custom.onEvent = { [weak self] in self?.activities.show($0) }

        NotificationCenter.default.addObserver(forName: .notchStartTimer, object: nil, queue: .main) { [weak self] n in
            guard let self, let minutes = n.object as? Int else { return }
            self.timer.start(minutes: minutes)
            self.closeLauncher()
        }
        NotificationCenter.default.addObserver(forName: .notchModulesChanged, object: nil, queue: .main) { [weak self] _ in
            self?.applyModuleSettings()
        }
        NotificationCenter.default.addObserver(forName: .notchClearLocalData, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.clipboard.clear()
            self.clearAll()
            self.launcher.clearHistory()
            self.shelf.clear()
            self.dismissedHints.removeAll()
            self.sessionDismissedHints.removeAll()
            UserDefaults.standard.removeObject(forKey: "dismissedHints")
            self.updateHint(mediaProblem: self.mediaController.problem)
        }
    }

    private func show(_ activity: LiveActivity, when key: KeyPath<AppSettings, Bool>) {
        guard settings[keyPath: key] else { return }
        activities.show(activity)
    }

    /// Starts/stops modules to match Settings. Safe to call repeatedly.
    func applyModuleSettings() {
        toggle("media", settings.mediaEnabled, on: { mediaController.start() },
               off: { mediaController.stop(); media = nil })
        toggle("notifications", settings.notificationsEnabled, on: { notificationWatcher.start() },
               off: { notificationWatcher.stop(); banner = nil })
        toggle("clipboard", settings.clipboardEnabled, on: { clipboard.start() }, off: { clipboard.stop() })
        toggle("downloads", settings.downloadsEnabled, on: { downloads.start() }, off: { downloads.stop() })
        // IOBluetooth triggers macOS's one-time Bluetooth permission prompt on first use; start it a
        // few seconds after launch so that dialog doesn't land on top of the island's first open.
        toggle("bluetooth", settings.bluetoothEnabled, on: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, self.settings.bluetoothEnabled else { return }
                self.bluetooth.start()
            }
        }, off: { bluetooth.stop() })
        toggle("battery", settings.batteryAlertsEnabled, on: { battery.start() }, off: { battery.stop() })
        toggle("calendar", settings.calendarEnabled, on: { calendar.start() }, off: { calendar.stop() })
        volume.syncEventTap()
        if !settings.volumeHUDEnabled { volume.dismissHUD() }
        indicatorsOn = settings.indicatorsEnabled && (status.micInUse || status.cameraInUse || status.focusName != nil)
        refreshLayout()
    }

    private func toggle(_ name: String, _ enabled: Bool, on: () -> Void, off: () -> Void) {
        if enabled, !running.contains(name) { running.insert(name); on() }
        else if !enabled, running.contains(name) { running.remove(name); off() }
    }

    // MARK: - Quiet Mode

    func toggleQuiet() { settings.setQuiet(!settings.quietManualOn) }

    /// Why the island is quiet, for the hover chip and tooltips; nil when it is not.
    var quietReason: String? {
        guard isQuiet else { return nil }
        if settings.quietManualOn {
            guard settings.quietUntil > 0 else { return "Quiet Mode is on" }
            let end = Date(timeIntervalSince1970: settings.quietUntil)
            return "Quiet until \(end.formatted(date: .omitted, time: .shortened))"
        }
        return "Quiet while \(status.focusName ?? "Focus") is on"
    }

    private func refreshQuiet() {
        quietExpiry?.cancel()
        if settings.quietMode, settings.quietUntil > 0 {
            let left = settings.quietUntil - Date().timeIntervalSince1970
            if left <= 0 {
                settings.setQuiet(false)      // posts didChange, which lands back here
                return
            }
            let work = DispatchWorkItem { [weak self] in self?.refreshQuiet() }
            quietExpiry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + left + 0.5, execute: work)
        }
        // KRAMAISLAND_QUIET=1 forces it for previews without touching the saved settings.
        let quiet = settings.quietManualOn || (settings.quietWithFocus && status.focusName != nil)
            || ProcessInfo.processInfo.environment["KRAMAISLAND_QUIET"] == "1"
        if quiet != isQuiet {
            withAnimation(Motion.quick) { isQuiet = quiet }
            if quiet {
                activities.silence()
                dismissBanner()
            }
        } else if quiet {
            refreshLayout()                   // "hide the ears" may have been flipped
        }
    }

    /// The gate every live activity passes (ActivityCenter.allows).
    private func allowsWhileQuiet(_ activity: LiveActivity) -> Bool {
        guard isQuiet else { return true }
        switch activity.kind {
        case .timer: return settings.quietAllowTimer
        case .battery: return settings.quietAllowLowBattery && activity.id == "battery.low"
        case .custom: return settings.quietAllowCustom
        default: return false
        }
    }

    // MARK: - Notification list

    var visibleRecent: [NotchNotification] {
        guard settings.notificationsEnabled else { return [] }
        let muted = settings.mutedNotificationAppIDs
        return recent
            .filter { !dismissed.contains($0.id) && !muted.contains($0.bundleID) && !muted.contains($0.appName.lowercased()) }
            .sorted { $0.date > $1.date }
    }

    var unreadCount: Int { visibleRecent.count }

    var hasNotifications: Bool { !visibleRecent.isEmpty }

    var availableNotificationCategories: [NotchNotification.Category] {
        let present = Set(visibleRecent.map(\.category))
        return NotchNotification.Category.allCases.filter { present.contains($0) }
    }

    var groups: [NotificationGroup] {
        let filtered: [NotchNotification]
        if let cat = selectedNotificationCategory {
            let matching = visibleRecent.filter { $0.category == cat }
            filtered = matching.isEmpty ? visibleRecent : matching
        } else {
            filtered = visibleRecent
        }
        var order: [String] = []
        var map: [String: [NotchNotification]] = [:]
        for note in filtered {
            if map[note.bundleID] == nil { order.append(note.bundleID); map[note.bundleID] = [] }
            map[note.bundleID]?.append(note)
        }
        return order.map { NotificationGroup(bundleID: $0, appName: map[$0]!.first!.appName, notes: map[$0]!) }
    }

    var bannerDuration: TimeInterval { max(2.5, settings.notificationBannerDuration) }

    var footerNotification: NotchNotification? {
        guard settings.notificationsEnabled, let latest, !dismissed.contains(latest.id),
              Date().timeIntervalSince(latest.date) < Self.recentLifetime else { return nil }
        return latest
    }

    private func loadHistory(_ history: [NotchNotification]) {
        let known = Set(recent.map(\.id))
        recent.append(contentsOf: history.filter { !known.contains($0.id) })
        trimRecent()
        refreshLayout()
    }

    // MARK: - Layout

    private func refreshLayout() {
        var l = IslandLayout()
        let unreadEar = settings.notificationsEnabled && settings.notificationUnreadDot && hasNotifications
        let ears = (media != nil || timerActive || indicatorsOn || stickyActivity != nil || unreadEar)
            && !(isQuiet && settings.quietHidesEars)
        l.mode = isLauncherOpen ? .launcher
               : isShadeOpen ? .shade
               : banner != nil ? .banner
               : (isExpanded || isDragTargeted) ? .expanded
               : volumeHUDVisible ? .volume
               : activity != nil ? .activity
               : ears ? .compact
               : .collapsed
        l.showsMedia = media != nil
        l.compactEars = ears
        l.showsFooter = footerNotification != nil || hint != nil
        l.customWidth = settings.clampedIslandWidth
        l.customHeight = settings.clampedIslandHeight
        l.compactWidthOffset = settings.clampedCompactWidthOffset
        l.compactHeightOffset = settings.clampedCompactHeightOffset
        if l != layout { layout = l }
    }

    func setSizePreview(_ active: Bool) {
        isSizePreviewActive = active
        if active {
            if !isShadeOpen {
                withAnimation(Motion.spring) {
                    isLauncherOpen = false
                    banner = nil
                    isShadeOpen = true
                }
            }
        } else if isShadeOpen {
            closeShade()
        }
    }

    private func updateHint(mediaProblem: String?) {
        let candidates = [mediaProblem.map { IslandHint(text: $0) }, notificationProblem, accessibilityProblem]
        let combined = candidates.compactMap { $0 }.first {
            !dismissedHints.contains($0.text) && !sessionDismissedHints.contains($0.text)
        }
        if combined != hint { hint = combined }
    }

    func dismissHint() {
        guard let current = hint else { return }
        if current.settingsPane == nil {
            dismissedHints.insert(current.text)
            UserDefaults.standard.set(Array(dismissedHints), forKey: "dismissedHints")
        } else {
            sessionDismissedHints.insert(current.text)
        }
        withAnimation(Motion.quick) {
            updateHint(mediaProblem: mediaController.problem)
        }
    }

    /// Without Accessibility the hotkey is not seen while another app is frontmost, so say so.
    func setAccessibilityGranted(_ granted: Bool) {
        let problem = granted ? nil : IslandHint(
            text: "Hotkey: allow KramaIsland under Accessibility. Already on? Settings ▸ Permissions ▸ Reset.",
            settingsPane: PrivacyPane.accessibility)
        guard problem != accessibilityProblem else { return }
        accessibilityProblem = problem
        updateHint(mediaProblem: mediaController.problem)
    }

    // MARK: - Hover

    /// Hover-enter uses `hoverDelay` (default 30 ms for near-instant open); hover-exit waits
    /// briefly so grazing the edge doesn't flicker.
    func setHovering(_ hovering: Bool) {
        hoverWork?.cancel()
        if hovering {
            guard !isExpanded else { return }
            let delay = settings.hoverDelay
            if delay <= 0.005 {
                withAnimation(Motion.spring) { self.isExpanded = true }
                return
            }
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.isExpanded else { return }
                withAnimation(Motion.spring) { self.isExpanded = true }
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isExpanded else { return }
                withAnimation(Motion.spring) { self.isExpanded = false }
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
    }

    private func hoverChanged() {
        if banner != nil {
            if isExpanded { bannerTimer?.cancel() } else { scheduleBannerDismiss(after: 1.5) }
        }
        refreshLayout()
    }

    // MARK: - Notifications

    private func present(_ note: NotchNotification) {
        guard settings.notificationsEnabled else { return }
        let muted = settings.mutedNotificationAppIDs
        guard !muted.contains(note.bundleID), !muted.contains(note.appName.lowercased()) else { return }

        if !recent.contains(where: { $0.id == note.id || ($0.dedupeKey == note.dedupeKey && abs($0.date.timeIntervalSince(note.date)) < 15) }) {
            recent.insert(note, at: 0)
        }
        trimRecent()
        latest = note
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.recentLifetime + 1) { [weak self] in
            self?.refreshLayout()
        }
        guard !isShadeOpen, !isLauncherOpen, !isQuiet else { return }

        if settings.notificationSound {
            NSSound(named: "Pop")?.play()
        } else {
            Feedback.tap()
        }

        // Queue rapid bursts instead of overwriting the visible banner.
        if let current = banner, current.id != note.id {
            if !bannerQueue.contains(where: { $0.id == note.id || $0.dedupeKey == note.dedupeKey }) {
                bannerQueue.append(note)
                if bannerQueue.count > 12 { bannerQueue.removeFirst() }
                bannerQueueCount = bannerQueue.count
            }
            return
        }

        withAnimation(Motion.spring) { banner = note }
        if isBannerHovered { bannerTimer?.cancel() } else { scheduleBannerDismiss(after: bannerDuration) }
    }

    private func trimRecent() {
        recent.sort { $0.date > $1.date }
        if recent.count > 100 { recent.removeLast(recent.count - 100) }
    }

    func setBannerHovered(_ hovering: Bool) {
        guard hovering != isBannerHovered else { return }
        isBannerHovered = hovering
        guard banner != nil else { return }
        if hovering {
            bannerTimer?.cancel()
        } else {
            scheduleBannerDismiss(after: 1.5)
        }
    }

    func dismissBanner() {
        bannerTimer?.cancel()
        if !bannerQueue.isEmpty {
            let next = bannerQueue.removeFirst()
            bannerQueueCount = bannerQueue.count
            withAnimation(Motion.spring) { banner = next }
            if !isBannerHovered { scheduleBannerDismiss(after: bannerDuration) }
            return
        }
        isBannerHovered = false
        withAnimation(Motion.quick) { banner = nil }
    }

    func openShadeFromBanner() {
        bannerTimer?.cancel()
        bannerQueue.removeAll()
        bannerQueueCount = 0
        isBannerHovered = false
        openShade()
    }

    func muteNotifications(for bundleID: String, appName: String) {
        settings.setNotificationAppMuted(bundleID, muted: true)
        bannerQueue.removeAll { $0.bundleID == bundleID }
        bannerQueueCount = bannerQueue.count
        if banner?.bundleID == bundleID { dismissBanner() }
        if latest?.bundleID == bundleID { latest = nil }
        Feedback.tap()
        refreshLayout()
    }

    func copyOTP(_ code: String, dismissBannerAfter: Bool = false) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(code, forType: .string)
        Feedback.tap()
        if dismissBannerAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.dismissBanner()
            }
        }
    }

    func openNotificationURL(_ url: URL, note: NotchNotification) {
        NSWorkspace.shared.open(url)
        dismiss(note)
        if banner?.id == note.id { dismissBanner() }
    }

    /// Fires a realistic sample notification right through KramaIsland's banner & shade pipeline.
    func sendTestNotification() {
        let now = Date()
        let samples: [NotchNotification] = [
            NotchNotification(
                id: "test.\(UUID().uuidString)",
                bundleID: "com.apple.MobileSMS",
                appName: "Messages",
                title: "Security Verification",
                subtitle: "Apple ID",
                body: "Your verification code is 482910. Never share this code with anyone.",
                date: now
            ),
            NotchNotification(
                id: "test.\(UUID().uuidString)",
                bundleID: "com.apple.iCal",
                appName: "Calendar",
                title: "Product Design Sync",
                subtitle: "Starts in 5 minutes",
                body: "Join Google Meet: https://meet.google.com/krm-isld-pro",
                date: now
            ),
            NotchNotification(
                id: "test.\(UUID().uuidString)",
                bundleID: "com.apple.mail",
                appName: "Mail",
                title: "GitHub · Seavik2142/KramaIsland",
                subtitle: "Release v1.4.0 Published",
                body: "Your signed build and DMG are live and ready for macOS users.",
                date: now
            ),
        ]
        let sample = samples[testSampleIndex % samples.count]
        testSampleIndex += 1
        present(sample)
    }

    func openBanner() {
        guard let note = banner else { return }
        open(note)
    }

    func open(_ note: NotchNotification) {
        if let url = AppIconCache.url(for: note.bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        }
        dismiss(note)
        if banner?.id == note.id { dismissBanner() }
    }

    func dismiss(_ note: NotchNotification) {
        withAnimation(Motion.quick) {
            _ = dismissed.insert(note.id)
            if latest?.id == note.id { latest = nil }
        }
    }

    func dismissGroup(_ group: NotificationGroup) {
        withAnimation(Motion.quick) {
            dismissed.formUnion(group.notes.map(\.id))
            if let latest, group.notes.contains(where: { $0.id == latest.id }) { self.latest = nil }
        }
    }

    func clearAll() {
        bannerTimer?.cancel()
        bannerQueue.removeAll()
        bannerQueueCount = 0
        withAnimation(Motion.quick) {
            dismissed.formUnion(recent.map(\.id))
            latest = nil
            banner = nil
            selectedNotificationCategory = nil
        }
        Feedback.tap()
    }

    func clearLatest() { if let latest { dismiss(latest) } }

    private func scheduleBannerDismiss(after seconds: TimeInterval) {
        bannerTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismissBanner() }
        bannerTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    // MARK: - Shade

    func toggleShade() {
        if ProcessInfo.processInfo.environment["KRAMAISLAND_DEBUG"] != nil { NSLog("KramaIsland: toggleShade (was open: %d)", isShadeOpen ? 1 : 0) }
        Feedback.tap()
        withAnimation(Motion.spring) {
            if isLauncherOpen { isLauncherOpen = false; query = "" }
            isShadeOpen.toggle()
            if isShadeOpen { banner = nil }
        }
    }

    func openShade() {
        guard !isShadeOpen else { return }
        toggleShade()
    }

    func closeShade() {
        isSizePreviewActive = false
        withAnimation(Motion.quick) { isShadeOpen = false }
        showMirror = false
    }

    // MARK: - Launcher

    var results: [LauncherItem] { launcher.results(for: query, apps: apps) }

    func toggleLauncher() {
        DispatchQueue.main.async {
            withAnimation(Motion.spring) {
                if self.isShadeOpen { self.isShadeOpen = false }
                self.isLauncherOpen.toggle()
            }
            if !self.isLauncherOpen { self.query = "" }
        }
    }

    func openLauncherFromShade() {
        withAnimation(Motion.spring) {
            isShadeOpen = false
            isLauncherOpen = true
        }
    }

    func closeLauncher() {
        withAnimation(Motion.quick) { isLauncherOpen = false }
        query = ""
    }

    func perform(_ item: LauncherItem) {
        switch item.kind {
        case .app(let app):
            launcher.recordLaunch(app)
            NSWorkspace.shared.openApplication(at: app.url, configuration: .init())
        case .calc(let text), .convert(let text):
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        case .file(let url):
            NSWorkspace.shared.open(url)
        case .clipboard(let item):
            clipboard.copy(item)
        case .action(let action):
            action.run()
        }
        Feedback.tap()
        closeLauncher()
    }

    private func quickActions() -> [QuickAction] {
        [
            QuickAction(id: "lock", title: "Lock Screen", symbol: "lock.fill", keywords: ["lock"]) { QuickSystem.lockScreen() },
            QuickAction(id: "sleep", title: "Sleep", symbol: "moon.zzz.fill", keywords: ["sleep"]) { QuickSystem.sleepMac() },
            QuickAction(id: "trash", title: "Empty Trash", symbol: "trash.fill", keywords: ["trash", "empty"]) { QuickSystem.emptyTrash() },
            QuickAction(id: "dark", title: "Toggle Dark Mode", symbol: "circle.lefthalf.filled", keywords: ["dark", "light", "appearance", "theme"]) { QuickSystem.toggleDarkMode() },
            QuickAction(id: "awake", title: "Toggle Keep Awake", symbol: "cup.and.saucer.fill", keywords: ["caffeine", "awake", "amphetamine", "sleep"]) { [weak self] in self?.caffeine.toggle() },
            QuickAction(id: "wifi", title: "Toggle Wi-Fi", symbol: "wifi", keywords: ["wifi", "wireless", "network"]) {
                DispatchQueue.global(qos: .userInitiated).async {
                    if let on = QuickSystem.wifiIsOn() { QuickSystem.setWifi(!on) }
                }
            },
            QuickAction(id: "mirror", title: "Camera Mirror", symbol: "camera.fill", keywords: ["camera", "mirror", "preview", "meeting"]) { [weak self] in
                self?.showMirror = true
                self?.openShade()
            },
            QuickAction(id: "pomodoro", title: "Start 25 minute Pomodoro", symbol: "timer", keywords: ["pomodoro", "focus", "timer"]) { [weak self] in self?.timer.start(minutes: 25) },
            QuickAction(id: "quiet", title: "Toggle Quiet Mode", symbol: "bell.slash.fill", keywords: ["quiet", "silent", "mute", "dnd", "disturb", "hide"]) { [weak self] in self?.toggleQuiet() },
            QuickAction(id: "quiet.hour", title: "Quiet Mode for 1 Hour", symbol: "bell.slash.fill", keywords: ["quiet", "silent", "mute", "hour"]) { [weak self] in self?.settings.setQuiet(true, for: 3600) },
            QuickAction(id: "window.left", title: "Snap Window Left Half", symbol: "rectangle.lefthalf.filled", keywords: ["snap", "window", "left", "half", "split", "tile"]) { WindowManager.shared.snap(.leftHalf) },
            QuickAction(id: "window.right", title: "Snap Window Right Half", symbol: "rectangle.righthalf.filled", keywords: ["snap", "window", "right", "half", "split", "tile"]) { WindowManager.shared.snap(.rightHalf) },
            QuickAction(id: "window.max", title: "Fill / Maximize Window", symbol: "arrow.up.left.and.arrow.down.right", keywords: ["snap", "window", "fill", "maximize", "full"]) { WindowManager.shared.snap(.maximize) },
            QuickAction(id: "window.center", title: "Center Window", symbol: "rectangle.center.inset.filled", keywords: ["snap", "window", "center"]) { WindowManager.shared.snap(.center) },
            QuickAction(id: "window.restore", title: "Restore Window Size", symbol: "arrow.uturn.backward", keywords: ["snap", "window", "restore", "undo"]) { WindowManager.shared.restore() },
            QuickAction(id: "tile.2", title: "Tile 2 Apps Side-by-Side", symbol: "rectangle.split.2x1.fill", keywords: ["tile", "split", "2", "two", "side", "window", "multi", "display"]) { WindowManager.shared.tile(.splitTwo) },
            QuickAction(id: "tile.focus", title: "Tile 2 Apps (2/3 + 1/3)", symbol: "sidebar.right", keywords: ["tile", "focus", "split", "thirds", "window", "display"]) { WindowManager.shared.tile(.focusTwo) },
            QuickAction(id: "tile.3", title: "Tile 3 Apps in Columns", symbol: "rectangle.split.3x1.fill", keywords: ["tile", "3", "three", "columns", "thirds", "window", "display"]) { WindowManager.shared.tile(.threeColumns) },
            QuickAction(id: "tile.4", title: "Tile 4 Apps in 2×2 Grid", symbol: "rectangle.split.2x2.fill", keywords: ["tile", "4", "four", "grid", "quarters", "window", "display"]) { WindowManager.shared.tile(.gridFour) },
            QuickAction(id: "tile.custom", title: "Tile Project Grid (Custom Rows × Cols)", symbol: "square.grid.3x2.fill", keywords: ["tile", "grid", "row", "rows", "col", "column", "columns", "custom", "project", "window", "layout"]) { WindowManager.shared.tileCustomGrid() },
            QuickAction(id: "clipboard.clear", title: "Clear Clipboard History", symbol: "doc.on.clipboard", keywords: ["clipboard", "clear", "copy", "wipe", "history"]) { [weak self] in self?.clipboard.clear() },
            QuickAction(id: "notifications.clear", title: "Clear All Notifications", symbol: "bell.slash", keywords: ["notifications", "clear", "dismiss", "alerts"]) { [weak self] in self?.clearAll() },
            QuickAction(id: "notifications.test", title: "Send Test Notification", symbol: "bell.badge.fill", keywords: ["notification", "test", "preview", "banner", "otp"]) { [weak self] in self?.sendTestNotification() },
            QuickAction(id: "volume.mute", title: "Toggle Mute Volume", symbol: "speaker.slash.fill", keywords: ["volume", "mute", "unmute", "sound", "audio"]) { [weak self] in self?.volume.toggleMute(showHUD: true) },
            QuickAction(id: "volume.up", title: "Volume Up", symbol: "speaker.wave.3.fill", keywords: ["volume", "louder", "up", "sound", "audio"]) { [weak self] in self?.volume.step(up: true) },
            QuickAction(id: "volume.down", title: "Volume Down", symbol: "speaker.wave.1.fill", keywords: ["volume", "quieter", "down", "sound", "audio"]) { [weak self] in self?.volume.step(up: false) },
            QuickAction(id: "settings", title: "KramaIsland Settings", symbol: "gear", keywords: ["settings", "preferences", "options"]) { SettingsWindowController.shared.show() },
        ]
    }

    // MARK: - Demo mode

    /// `KRAMAISLAND_DEMO=1`: stop the live media, notification and clipboard sources and show
    /// sample content instead, so screenshots carry no personal data. Focus, battery, camera and
    /// mic indicators stay real.
    func seedDemo() {
        mediaController.stop()
        notificationWatcher.stop()
        clipboard.stop()
        notificationProblem = nil
        hint = nil
        dismissed = []

        let now = Date()
        func note(_ id: String, _ bundle: String, _ app: String, _ title: String, _ body: String,
                  _ minutesAgo: Double) -> NotchNotification {
            NotchNotification(id: "demo.\(id)", bundleID: bundle, appName: app, title: title, subtitle: "",
                              body: body, date: now.addingTimeInterval(-minutesAgo * 60))
        }
        let notes = [
            note("m1", "com.apple.MobileSMS", "Messages", "Maya Chen", "Lunch at 1? The new ramen place just opened 🍜", 1),
            note("m2", "com.apple.MobileSMS", "Messages", "Maya Chen", "Also bring the charger you borrowed 😅", 3),
            note("c1", "com.apple.iCal", "Calendar", "Design review", "Starts in 15 minutes · Conference Room B", 9),
            note("r1", "com.apple.reminders", "Reminders", "Water the plants", "Today, 6:00 PM", 26),
            note("e1", "com.apple.mail", "Mail", "App Store Connect", "Your build 1.0.0 (42) has completed processing.", 41),
        ]
        recent = notes
        latest = notes[0]

        calendar.seed(CalendarModule.NextEvent(
            title: "Design review", start: now.addingTimeInterval(15 * 60), end: now.addingTimeInterval(60 * 60),
            location: "Conference Room B", joinURL: URL(string: "https://meet.google.com/abc-defg-hij"), color: UI.info))
        clipboard.seed(["https://github.com/Seavik2142/KramaIsland", "swift build -c release",
                        "Ship v1.0 on Friday, demo at 3 pm"])
        timer.start(minutes: 25, alreadyElapsed: 7 * 60 + 18)

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("KramaIslandDemo", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let files = ["Q4 Roadmap.pdf", "Hero shot.png", "Launch notes.md"].map { tmp.appendingPathComponent($0) }
        for f in files where !FileManager.default.fileExists(atPath: f.path) {
            FileManager.default.createFile(atPath: f.path, contents: Data())
        }
        shelf.add(files)

        // The media controller's last value lands on the main queue after stop(); seed after it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.media = NowPlaying(player: .music, title: "Midnight City", artist: "M83",
                                    album: "Hurry Up, We're Dreaming", isPlaying: true, elapsed: 73, duration: 244,
                                    trackID: "demo", artworkHint: "", artwork: Self.demoArtwork(), sampledAt: Date())
        }
    }

    func demoBanner() {
        guard let note = recent.first else { return }
        withAnimation(Motion.spring) { banner = note }
    }

    func demoActivity() {
        activities.show(LiveActivity(id: "demo.airpods", kind: .bluetooth, symbol: "airpodspro", title: "AirPods Pro",
                                     subtitle: "L 84% · R 82% · Case 61%", progress: nil, tint: UI.info, duration: 30))
    }

    private static func demoArtwork() -> NSImage {
        NSImage(size: NSSize(width: 300, height: 300), flipped: false) { rect in
            NSGradient(colorsAndLocations:
                (NSColor(calibratedRed: 0.98, green: 0.45, blue: 0.40, alpha: 1), 0),
                (NSColor(calibratedRed: 0.62, green: 0.30, blue: 0.95, alpha: 1), 0.6),
                (NSColor(calibratedRed: 0.15, green: 0.20, blue: 0.55, alpha: 1), 1))!
                .draw(in: rect, angle: -55)
            NSColor.white.withAlphaComponent(0.18).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 70, dy: 70)).fill()
            NSColor.white.withAlphaComponent(0.92).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 118, dy: 118)).fill()
            NSColor(calibratedRed: 0.62, green: 0.30, blue: 0.95, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 138, dy: 138)).fill()
            return true
        }
    }

    private func loadApps() {
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications",
                    "/System/Applications/Utilities",
                    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var found: [URL: AppEntry] = [:]
        for dir in dirs {
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) else { continue }
            for url in items where url.pathExtension == "app" {
                found[url] = AppEntry(url: url)
            }
        }
        apps = found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
