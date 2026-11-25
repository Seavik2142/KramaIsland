import AppKit
import ApplicationServices
import SQLite3
import SwiftUI

// MARK: - Rich Notification Model

/// One delivered system notification, enriched with category classification, smart OTP / link
/// extraction, and platform attribution.
struct NotchNotification: Identifiable, Equatable {
    enum Category: String, CaseIterable, Identifiable, Equatable {
        case message = "Messages"
        case mail = "Mail"
        case calendar = "Calendar"
        case work = "Work"
        case social = "Social"
        case system = "System"
        case other = "Other"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .message: return "message.fill"
            case .mail: return "envelope.fill"
            case .calendar: return "calendar"
            case .work: return "hammer.fill"
            case .social: return "sparkles"
            case .system: return "gearshape.fill"
            case .other: return "bell.fill"
            }
        }

        var tint: Color {
            switch self {
            case .message: return UI.success
            case .mail: return UI.info
            case .calendar: return UI.timer
            case .work: return UI.focus
            case .social: return Color(red: 0.96, green: 0.44, blue: 0.62)
            case .system: return Color.white.opacity(0.75)
            case .other: return UI.info
            }
        }
    }

    let id: String
    let bundleID: String
    let appName: String
    let title: String
    let subtitle: String
    let body: String
    let date: Date
    let threadID: String?
    let category: Category
    let otpCode: String?
    let actionURL: URL?

    init(
        id: String,
        bundleID: String,
        appName: String,
        title: String,
        subtitle: String,
        body: String,
        date: Date,
        threadID: String? = nil,
        category: Category? = nil,
        otpCode: String? = nil,
        actionURL: URL? = nil
    ) {
        self.id = id
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.date = date
        self.threadID = threadID
        self.category = category ?? Self.classify(bundleID: bundleID, appName: appName, title: title, body: body)
        self.otpCode = otpCode ?? Self.extractOTP(from: [title, subtitle, body].joined(separator: " "))
        self.actionURL = actionURL ?? Self.extractURL(from: [subtitle, body, title].joined(separator: " "))
    }

    var icon: NSImage { AppIconCache.icon(for: bundleID, appName: appName) }

    var headline: String {
        if !title.isEmpty { return title }
        if !subtitle.isEmpty { return subtitle }
        return appName
    }

    /// Clean caption for eyebrow (e.g. "YouTube · Chrome" for browser web push, or app name).
    var sourceLabel: String {
        let b = bundleID.lowercased()
        let isBrowser = b.contains("chrome") || b.contains("safari") || b.contains("brave")
            || b.contains("edge") || b.contains("arc") || b.contains("vivaldi")
            || b.contains("opera") || b.contains("firefox")
        if isBrowser, !subtitle.isEmpty, subtitle.contains("."), !subtitle.contains(" ") {
            let cleanHost = subtitle
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
                .replacingOccurrences(of: "www.", with: "")
                .split(separator: "/").first.map(String.init) ?? subtitle
            return "\(cleanHost) · \(appName)"
        }
        return appName
    }

    /// True when the extracted URL looks like a video meeting link.
    var isMeetingLink: Bool {
        guard let host = actionURL?.host?.lowercased() else { return false }
        return host.contains("zoom.us") || host.contains("meet.google") || host.contains("teams.microsoft")
            || host.contains("webex.com") || host.contains("whereby.com") || host.contains("around.co")
            || host.contains("facetime.apple") || host.contains("gather.town")
    }

    /// Normalized deduplication fingerprint shared across the SQLite and Live AX engines.
    var dedupeKey: String {
        let normApp = appName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let normTitle = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let normBody = body.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(normApp)|\(normTitle)|\(normBody)"
    }

    static func == (a: NotchNotification, b: NotchNotification) -> Bool {
        a.id == b.id && a.title == b.title && a.body == b.body
    }

    // MARK: - Smart Classification, OTP & Link Extraction

    static func classify(bundleID: String, appName: String, title: String, body: String) -> Category {
        let key = "\(bundleID) \(appName)".lowercased()
        if key.contains("mobilesms") || key.contains("messages") || key.contains("whatsapp")
            || key.contains("telegram") || key.contains("messenger") || key.contains("signal")
            || key.contains("slack") || key.contains("discord") || key.contains("teams")
            || key.contains("wechat") || key.contains("line") || key.contains("viber")
            || key.contains("facetime") || key.contains("zoom") {
            return .message
        }
        if key.contains("mail") || key.contains("outlook") || key.contains("spark")
            || key.contains("mimestream") || key.contains("airmail") || key.contains("thunderbird")
            || key.contains("gmail") {
            return .mail
        }
        if key.contains("ical") || key.contains("calendar") || key.contains("fantastical")
            || key.contains("reminders") || key.contains("todoist") || key.contains("things")
            || key.contains("clock") {
            return .calendar
        }
        if key.contains("xcode") || key.contains("vscode") || key.contains("code")
            || key.contains("antigravity") || key.contains("cursor") || key.contains("terminal")
            || key.contains("iterm") || key.contains("warp") || key.contains("github")
            || key.contains("linear") || key.contains("jira") || key.contains("figma")
            || key.contains("notion") || key.contains("docker") || key.contains("postman") {
            return .work
        }
        if key.contains("twitter") || key.contains("instagram") || key.contains("facebook")
            || key.contains("tiktok") || key.contains("reddit") || key.contains("youtube")
            || key.contains("linkedin") || key.contains("threads") {
            return .social
        }
        if key.hasPrefix("com.apple.") || key.contains("system") || key.contains("finder")
            || key.contains("softwareupdate") || key.contains("screentime") || key.contains("appstore") {
            return .system
        }
        return .other
    }

    private static let otpContextPattern = try! NSRegularExpression(
        pattern: #"(?i)\b(?:code|otp|passcode|pin|verification|verify|security|login|sign[\s-]?in|auth|2fa|token|confirm)\b.{0,28}?\b([A-Z]-?\d{4,8}|\d{4,8})\b|\b(\d{4,8})\b.{0,24}?\b(?:is your|verification|security|login|one[\s-]?time|passcode|otp)\b"#
    )

    static func extractOTP(from text: String) -> String? {
        guard text.count >= 6 else { return nil }
        let ns = text as NSString
        guard let m = otpContextPattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        for idx in 1..<m.numberOfRanges {
            let r = m.range(at: idx)
            if r.location != NSNotFound, r.length >= 4 {
                let raw = ns.substring(with: r)
                // Avoid matching bare years like 2025/2026 unless prefixed like G-2026
                if raw.count == 4, let yr = Int(raw), (1990...2099).contains(yr) { continue }
                return raw
            }
        }
        return nil
    }

    private static let urlDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func extractURL(from text: String) -> URL? {
        guard text.contains("http") || text.contains("zoom.us") || text.contains("meet.google") else { return nil }
        guard let detector = urlDetector else { return nil }
        let ns = text as NSString
        let matches = detector.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            if let url = m.url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" {
                return url
            }
        }
        return nil
    }
}

// MARK: - App Icon & Friendly Name Resolution

enum AppIconCache {
    private static var icons: [String: NSImage] = [:]
    private static var fileIcons: [String: NSImage] = [:]
    private static var nameToBundle: [String: String] = [:]
    private static let lock = NSLock()

    private static let systemFriendlyNames: [String: String] = [
        "com.apple.mobilesms": "Messages",
        "com.apple.ical": "Calendar",
        "com.apple.mail": "Mail",
        "com.apple.reminders": "Reminders",
        "com.apple.facetime": "FaceTime",
        "com.apple.notes": "Notes",
        "com.apple.finder": "Finder",
        "com.apple.appstore": "App Store",
        "com.apple.systempreferences": "System Settings",
        "com.apple.softwareupdatenotification": "Software Update",
        "com.apple.screentimenotifications": "Screen Time",
        "com.apple.weather": "Weather",
        "com.apple.clock": "Clock",
        "com.apple.news": "News",
        "com.apple.podcasts": "Podcasts",
        "com.apple.music": "Music",
        "com.apple.tv": "TV",
        "com.apple.photos": "Photos",
        "com.apple.safari": "Safari",
        "com.apple.passbook": "Wallet",
        "com.apple.findmy": "Find My",
        "com.apple.home": "Home",
        "_system_center_": "macOS",
    ]

    static func fileIcon(for path: String) -> NSImage {
        lock.lock(); defer { lock.unlock() }
        if let cached = fileIcons[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        if fileIcons.count > 250 { fileIcons.removeAll() }
        fileIcons[path] = image
        return image
    }

    static func url(for bundleID: String) -> URL? {
        guard !bundleID.isEmpty else { return nil }
        if let direct = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return direct
        }
        // Safari/Chrome Web Apps often use suffixes like `com.apple.Safari.WebApp.<UUID>`
        if bundleID.hasPrefix("com.apple.Safari.WebApp") {
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
        }
        if bundleID.hasPrefix("com.google.Chrome.app.") {
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome")
        }
        if bundleID.hasPrefix("com.brave.Browser.app.") {
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.brave.Browser")
        }
        if bundleID.hasPrefix("com.microsoft.edgemac.app.") {
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.edgemac")
        }
        return nil
    }

    /// Resolves a bundle identifier from a display name (used by the Live AX Banner Observer).
    static func resolveBundleID(forAppName name: String) -> String {
        let key = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return "com.apple.notificationcenterui" }

        lock.lock()
        if let hit = nameToBundle[key] { lock.unlock(); return hit }
        lock.unlock()

        for (bid, friendly) in systemFriendlyNames where friendly.lowercased() == key {
            cacheNameMapping(key, bundleID: bid)
            return bid
        }
        for app in NSWorkspace.shared.runningApplications {
            if let loc = app.localizedName?.lowercased(), loc == key, let bid = app.bundleIdentifier {
                cacheNameMapping(key, bundleID: bid)
                return bid
            }
        }
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        for dir in dirs {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent("\(name).app")
            if let bundle = Bundle(url: candidate), let bid = bundle.bundleIdentifier {
                cacheNameMapping(key, bundleID: bid)
                return bid
            }
        }
        return "app.live.\(key.replacingOccurrences(of: " ", with: "-"))"
    }

    private static func cacheNameMapping(_ key: String, bundleID: String) {
        lock.lock(); defer { lock.unlock() }
        if nameToBundle.count > 200 { nameToBundle.removeAll() }
        nameToBundle[key] = bundleID
    }

    static func name(for bundleID: String) -> String {
        if let friendly = systemFriendlyNames[bundleID.lowercased()] { return friendly }
        if let url = url(for: bundleID) {
            let name = FileManager.default.displayName(atPath: url.path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        if bundleID.hasPrefix("com.apple.ncplugin.") {
            return bundleID.replacingOccurrences(of: "com.apple.ncplugin.", with: "").capitalized
        }
        let tail = bundleID.components(separatedBy: ".").last ?? bundleID
        return tail.isEmpty ? "Notification" : tail
    }

    static func icon(for bundleID: String, appName: String = "") -> NSImage {
        let cacheKey = bundleID.isEmpty ? appName : bundleID
        lock.lock(); defer { lock.unlock() }
        if let cached = icons[cacheKey] { return cached }
        let image: NSImage
        if let url = url(for: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else if !appName.isEmpty,
                  let fallbackURL = url(for: resolveBundleIDUnsafe(appName)) {
            image = NSWorkspace.shared.icon(forFile: fallbackURL.path)
        } else if bundleID.hasPrefix("com.apple.") || bundleID == "_SYSTEM_CENTER_" {
            image = NSWorkspace.shared.icon(forFile: "/System/Applications/System Settings.app")
        } else {
            image = NSImage(systemSymbolName: "bell.badge.fill", accessibilityDescription: nil) ?? NSImage()
        }
        if icons.count > 250 { icons.removeAll() }
        icons[cacheKey] = image
        return image
    }

    private static func resolveBundleIDUnsafe(_ name: String) -> String {
        let key = name.lowercased()
        for app in NSWorkspace.shared.runningApplications {
            if app.localizedName?.lowercased() == key, let bid = app.bundleIdentifier {
                return bid
            }
        }
        return ""
    }
}

// MARK: - Dual-Engine Notification Watcher

/// Watches ALL macOS notifications using a resilient dual-engine architecture:
///
/// 1. **Notification Center Database (`usernoted` SQLite + WAL watcher)** — when Full Disk Access
///    is granted, reads every delivered notification (native apps, web push, silent notifications,
///    24-hour history) across both macOS 15+ (`group.com.apple.usernoted`) and macOS 13–14
///    (`DARWIN_USER_DIR/com.apple.notificationcenter`).
/// 2. **Live Banner Observer (`com.apple.notificationcenterui` Accessibility AX observer)** — when
///    Accessibility is granted, captures EVERY live notification banner in <50 ms (even before
///    Full Disk Access is granted, and faster than `usernoted`'s lazy WAL flush!).
///
/// Both engines feed a unified deduplicator so every notification appears once, instantaneously,
/// with zero duplicates.
final class NotificationWatcher: ObservableObject {
    enum EngineStatus: Equatable {
        case fullAndLive      // Full Disk Access + Live AX banners active
        case fullOnly         // Full Disk Access active (SQLite/WAL)
        case liveOnly         // Live AX banners active (no history until Full Disk Access)
        case needsPermission  // Neither Full Disk Access nor Accessibility granted
    }

    @Published private(set) var engineStatus: EngineStatus = .needsPermission

    /// Called on the main thread for each new notification, oldest first.
    var onNotification: ((NotchNotification) -> Void)?
    /// Called once on the main thread at startup with notifications already in the Centre, newest first.
    var onHistory: (([NotchNotification]) -> Void)?
    /// Called on the main thread with the current problem (and the pane that fixes it), or nil when all is well.
    var onStatus: ((IslandHint?) -> Void)?
    /// Asked on the main thread before closing macOS's original top-right banner (false while Quiet Mode
    /// or hidden-by-policy is active, or when the user turned off native banner replacement).
    var shouldReplaceSystemBanner: (() -> Bool)?

    static let modernDatabaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")

    /// Resolves the active Notification Center database URL for macOS 15+ or macOS 13–14.
    static var databaseURL: URL {
        if FileManager.default.fileExists(atPath: modernDatabaseURL.deletingLastPathComponent().path) {
            return modernDatabaseURL
        }
        if let legacy = legacyDatabaseURL() {
            return legacy
        }
        return modernDatabaseURL
    }

    private static func legacyDatabaseURL() -> URL? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let len = confstr(_CS_DARWIN_USER_DIR, &buf, buf.count)
        guard len > 0 else { return nil }
        let base = String(cString: buf)
        let url = URL(fileURLWithPath: base).appendingPathComponent("com.apple.notificationcenter/db2/db")
        return FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) ? url : nil
    }

    /// Shown in the island and in Settings while the store can't be opened for lack of Full Disk Access.
    static let fullDiskAccessHint = IslandHint(
        text: "Grant Full Disk Access for full notification history & silent alerts.",
        settingsPane: PrivacyPane.fullDiskAccess)

    enum StoreAccess: Equatable {
        case ok
        case needsFullDiskAccess
        case missing
        case failed(String)

        var isUsable: Bool { self == .ok || self == .missing }
    }

    static func storeAccess() -> StoreAccess {
        let fd = Darwin.open(databaseURL.path, O_RDONLY)
        if fd >= 0 { Darwin.close(fd); return .ok }
        switch errno {
        case EPERM, EACCES: return .needsFullDiskAccess
        case ENOENT: return .missing
        default: return .failed(String(cString: strerror(errno)))
        }
    }

    private let queue = DispatchQueue(label: "KramaIsland.notifications", qos: .utility)
    private var db: OpaquePointer?
    private var startDate: Double = 0
    private var lastDate: Double = 0
    private var seenUUIDs: [String: Double] = [:]
    private var recentDedupe: [String: Date] = [:]   // dedupeKey -> delivery timestamp (main thread)
    private var timer: DispatchSourceTimer?
    private var walSource: DispatchSourceFileSystemObject?
    private var retryCount = 0
    private var reported: IslandHint?
    private var reportedOnce = false
    private let liveObserver = LiveBannerObserver()
    private var liveActive = false

    func start() {
        liveObserver.onBanner = { [weak self] note, element in
            self?.deliverLiveBanner(note, element: element)
        }
        liveObserver.onActiveChanged = { [weak self] active in
            self?.liveActive = active
            self?.refreshEngineStatus()
        }
        liveObserver.start()

        queue.async { [self] in
            openDatabase()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 1, repeating: 1.0)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    func stop() {
        liveObserver.stop()
        liveActive = false
        queue.async { [self] in
            timer?.cancel(); timer = nil
            walSource?.cancel(); walSource = nil
            if let db { sqlite3_close(db) }
            db = nil
            DispatchQueue.main.async { self.engineStatus = .needsPermission }
        }
    }

    /// Re-attaches the live AX observer when Accessibility is granted after launch.
    func refreshLiveObserver() {
        liveObserver.rearmIfNeeded()
        refreshEngineStatus()
    }

    deinit {
        liveObserver.stop()
        timer?.cancel()
        walSource?.cancel()
        if let db { sqlite3_close(db) }
    }

    // MARK: - Unified Deduplicated Delivery

    private func deliverLiveBanner(_ note: NotchNotification, element: AXUIElement) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let muted = AppSettings.shared.mutedNotificationAppIDs
            if muted.contains(note.bundleID) || muted.contains(note.appName.lowercased()) {
                return
            }

            // Close macOS's original top-right banner right after capturing it so only KramaIsland shows.
            if self.shouldReplaceSystemBanner?() ?? false {
                self.liveObserver.dismissOriginalBanner(element)
            }

            self.deliverIfFreshOnMain(note)
        }
    }

    private func deliverIfFresh(_ note: NotchNotification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let muted = AppSettings.shared.mutedNotificationAppIDs
            if muted.contains(note.bundleID) || muted.contains(note.appName.lowercased()) {
                return
            }
            if self.shouldReplaceSystemBanner?() ?? false {
                self.liveObserver.dismissMatchingBanners(for: note)
            }
            self.deliverIfFreshOnMain(note)
        }
    }

    private func deliverIfFreshOnMain(_ note: NotchNotification) {
        let now = Date()
        recentDedupe = recentDedupe.filter { now.timeIntervalSince($0.value) < 25 }
        let key = note.dedupeKey
        if let prev = recentDedupe[key], now.timeIntervalSince(prev) < 20 {
            return   // already surfaced by the companion engine
        }
        recentDedupe[key] = now
        onNotification?(note)
    }

    private func refreshEngineStatus() {
        let hasDB = (Self.storeAccess() == .ok)
        let hasLive = liveActive || AXIsProcessTrusted()
        let next: EngineStatus
        switch (hasDB, hasLive) {
        case (true, true): next = .fullAndLive
        case (true, false): next = .fullOnly
        case (false, true): next = .liveOnly
        case (false, false): next = .needsPermission
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.engineStatus != next { self.engineStatus = next }
            // Only show a setup warning hint when neither engine can capture alerts.
            if next == .liveOnly {
                self.onStatus?(nil)
            }
        }
    }

    // MARK: - Engine 1: SQLite / WAL Notification Center Store

    private func openDatabase() {
        var handle: OpaquePointer?
        let path = Self.databaseURL.path
        switch Self.storeAccess() {
        case .ok:
            break
        case .needsFullDiskAccess:
            refreshEngineStatus()
            if !liveActive && !AXIsProcessTrusted() {
                report(Self.fullDiskAccessHint)
            } else {
                report(nil)
            }
            return
        case .missing:
            refreshEngineStatus()
            report(nil)
            return
        case .failed(let why):
            refreshEngineStatus()
            report(IslandHint(text: "Notifications unavailable: \(why)"))
            return
        }
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        if rc == SQLITE_OK, let handle {
            db = handle
            startDate = Date().timeIntervalSinceReferenceDate
            lastDate = startDate
            refreshEngineStatus()
            report(nil)
            loadHistory()
            if walSource == nil { watchWAL() }
        } else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            refreshEngineStatus()
            if rc == SQLITE_AUTH || rc == SQLITE_PERM || rc == SQLITE_CANTOPEN {
                if !liveActive && !AXIsProcessTrusted() { report(Self.fullDiskAccessHint) }
            } else {
                report(IslandHint(text: "Notifications unavailable: \(message)"))
            }
        }
    }

    private func watchWAL() {
        let fd = Darwin.open(Self.databaseURL.path + "-wal", O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.poll()
            self.queue.asyncAfter(deadline: .now() + 0.25) { self.poll() }
            if source.data.contains(.delete) || source.data.contains(.rename) {
                source.cancel()
                self.queue.asyncAfter(deadline: .now() + 1) { self.watchWAL() }
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        walSource = source
    }

    private func tick() {
        if db == nil {
            retryCount += 1
            if retryCount % 10 == 0 { openDatabase() }
            return
        }
        poll()
    }

    private func report(_ problem: IslandHint?) {
        if !reportedOnce || problem != reported {
            reportedOnce = true
            reported = problem
            NSLog("KramaIsland notifications: %@", problem?.text ?? "ok")
        }
        DispatchQueue.main.async { self.onStatus?(problem) }
    }

    private func loadHistory() {
        guard let db else { return }
        let dayAgo = startDate - 24 * 3600
        let sql = """
            SELECT r.rec_id, a.identifier, r.data, r.delivered_date, hex(r.uuid)
            FROM record r JOIN app a ON a.app_id = r.app_id
            WHERE r.delivered_date > ? AND r.delivered_date <= ?
            ORDER BY r.delivered_date DESC LIMIT 80
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, dayAgo)
        sqlite3_bind_double(stmt, 2, startDate)

        var history: [NotchNotification] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let note = decode(stmt) {
                seenUUIDs[note.id] = note.date.timeIntervalSinceReferenceDate
                history.append(note)
            }
        }
        guard !history.isEmpty else { return }
        DispatchQueue.main.async { self.onHistory?(history) }
    }

    private func poll() {
        guard let db else { return }
        let sql = """
            SELECT r.rec_id, a.identifier, r.data, r.delivered_date, hex(r.uuid)
            FROM record r JOIN app a ON a.app_id = r.app_id
            WHERE r.delivered_date > ?
            ORDER BY r.delivered_date ASC
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, lastDate - 30)

        var fresh: [NotchNotification] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let delivered = sqlite3_column_double(stmt, 3)
            let uuid = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                ?? "rec-\(sqlite3_column_int64(stmt, 0))"
            guard seenUUIDs[uuid] == nil else { continue }
            seenUUIDs[uuid] = delivered
            guard delivered > startDate else { continue }
            lastDate = max(lastDate, delivered)
            if let note = decode(stmt) { fresh.append(note) }
        }

        let cutoff = lastDate - 120
        seenUUIDs = seenUUIDs.filter { $0.value > cutoff }
        fresh.forEach { deliverIfFresh($0) }
    }

    private func decode(_ stmt: OpaquePointer?) -> NotchNotification? {
        let recID = sqlite3_column_int64(stmt, 0)
        let delivered = sqlite3_column_double(stmt, 3)
        let uuid = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "rec-\(recID)"
        guard let bytes = sqlite3_column_blob(stmt, 2) else { return nil }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 2)))
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return nil }

        let req = plist["req"] as? [String: Any] ?? [:]
        let title = (req["titl"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = (req["subt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (req["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let threadID = (req["thrd"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(title.isEmpty && subtitle.isEmpty && body.isEmpty) else { return nil }

        let tableID = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        let bundleID = (plist["app"] as? String) ?? tableID
        // Skip our own test notifications from looping if ever posted externally.
        if bundleID == Bundle.main.bundleIdentifier { return nil }

        return NotchNotification(
            id: uuid,
            bundleID: bundleID,
            appName: AppIconCache.name(for: bundleID),
            title: title,
            subtitle: subtitle,
            body: body,
            date: Date(timeIntervalSinceReferenceDate: delivered),
            threadID: threadID?.isEmpty == true ? nil : threadID
        )
    }
}

// MARK: - Engine 2: Live Accessibility Banner Observer (com.apple.notificationcenterui)

/// Watches `com.apple.notificationcenterui` via macOS Accessibility to capture live notification
/// banners from ALL apps and browsers (Safari, Chrome, Messages, Slack, Discord, Telegram, Mail,
/// System alerts) in real time — even without Full Disk Access!
private final class LiveBannerObserver {
    var onBanner: ((NotchNotification, AXUIElement) -> Void)?
    var onActiveChanged: ((Bool) -> Void)?

    private var observer: AXObserver?
    private var watchedPID: pid_t = 0
    private var launchObserver: Any?
    private var pendingScan: DispatchWorkItem?
    private var retryScan: DispatchWorkItem?
    private var lastWindowFingerprints: [String: Date] = [:]
    private var running = false

    func start() {
        running = true
        if launchObserver == nil {
            launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == "com.apple.notificationcenterui" else { return }
                self?.attach(pid: app.processIdentifier)
            }
        }
        rearmIfNeeded()
    }

    func stop() {
        running = false
        pendingScan?.cancel(); pendingScan = nil
        retryScan?.cancel(); retryScan = nil
        detach()
        if let launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(launchObserver)
            self.launchObserver = nil
        }
    }

    func rearmIfNeeded() {
        guard running else { return }
        guard AXIsProcessTrusted() else {
            detach()
            return
        }
        guard let ncApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.notificationcenterui"
        ).first else {
            detach()
            return
        }
        if ncApp.processIdentifier != watchedPID || observer == nil {
            attach(pid: ncApp.processIdentifier)
        }
    }

    private func attach(pid: pid_t) {
        detach()
        var obs: AXObserver?
        let err = AXObserverCreate(pid, liveBannerAXCallback, &obs)
        guard err == .success, let obs else {
            onActiveChanged?(false)
            return
        }

        let appEl = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let notifications: [String] = [
            kAXWindowCreatedNotification as String,
            kAXLayoutChangedNotification as String,
            kAXCreatedNotification as String,
        ]
        var attachedAny = false
        for name in notifications {
            if AXObserverAddNotification(obs, appEl, name as CFString, refcon) == .success {
                attachedAny = true
            }
        }
        guard attachedAny else {
            onActiveChanged?(false)
            return
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observer = obs
        watchedPID = pid
        onActiveChanged?(true)
        NSLog("KramaIsland notifications: live banner AX observer active (NotificationCenter pid %d)", pid)
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        watchedPID = 0
        onActiveChanged?(false)
    }

    fileprivate func scheduleScan(element: AXUIElement) {
        pendingScan?.cancel()
        retryScan?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let foundAny = self.inspectNotificationCenterWindows(hintElement: element)
            if !foundAny {
                // If SwiftUI inside NotificationCenter was still laying out text at 40 ms,
                // do one quick follow-up pass 90 ms later.
                let retry = DispatchWorkItem { [weak self] in
                    _ = self?.inspectNotificationCenterWindows(hintElement: element)
                }
                self.retryScan = retry
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: retry)
            }
        }
        pendingScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
    }

    @discardableResult
    private func inspectNotificationCenterWindows(hintElement: AXUIElement) -> Bool {
        let candidates = activeBannerElements(hintElement: hintElement)
        guard !candidates.isEmpty else { return false }

        let now = Date()
        lastWindowFingerprints = lastWindowFingerprints.filter { now.timeIntervalSince($0.value) < 12 }
        var deliveredAny = false

        for bannerEl in candidates {
            guard let note = extractNotification(from: bannerEl) else { continue }
            deliveredAny = true
            let fp = note.dedupeKey
            if let prev = lastWindowFingerprints[fp], now.timeIntervalSince(prev) < 8 {
                continue
            }
            lastWindowFingerprints[fp] = now
            onBanner?(note, bannerEl)
        }
        return deliveredAny
    }

    /// Finds any live floating banner matching `note` (called when SQLite catches a notification first)
    /// and closes the original macOS banner cleanly.
    func dismissMatchingBanners(for note: NotchNotification) {
        guard watchedPID != 0 else { return }
        let appEl = AXUIElementCreateApplication(watchedPID)
        for bannerEl in activeBannerElements(hintElement: appEl) {
            if let extracted = extractNotification(from: bannerEl), extracted.dedupeKey == note.dedupeKey {
                dismissOriginalBanner(bannerEl)
            }
        }
    }

    /// Safely closes macOS's original top-right notification banner using only Close/Cancel AX
    /// actions (never pressing the notification body itself so apps are never accidentally opened).
    func dismissOriginalBanner(_ bannerEl: AXUIElement, allowRetry: Bool = true) {
        if performCloseOnBanner(bannerEl) {
            NSLog("KramaIsland notifications: dismissed original macOS banner")
            return
        }
        guard allowRetry else { return }
        // Occasionally NotificationCenter registers the Close action ~60 ms after banner creation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            if self.performCloseOnBanner(bannerEl) {
                NSLog("KramaIsland notifications: dismissed original macOS banner (retry)")
            }
        }
    }

    private func performCloseOnBanner(_ root: AXUIElement) -> Bool {
        // Pass 1: Look for native custom Close/Clear/Cancel AX actions on the banner container or
        // its immediate groups (macOS 13–27 exposes `"Name:Close\n..."` or `"AXCancel"`).
        var visited = 0
        func tryActions(_ el: AXUIElement, depth: Int) -> Bool {
            guard depth <= 5, visited < 80 else { return false }
            visited += 1

            let role = axString(el, kAXRoleAttribute) ?? ""
            if role != (kAXButtonRole as String), let action = matchingCloseAction(on: el) {
                if AXUIElementPerformAction(el, action as CFString) == .success {
                    return true
                }
            }

            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                for child in children {
                    if tryActions(child, depth: depth + 1) { return true }
                }
            }
            return false
        }

        if tryActions(root, depth: 0) { return true }

        // Pass 2: Look strictly for an explicit Close / Dismiss `AXButton` inside the banner.
        visited = 0
        func tryCloseButton(_ el: AXUIElement, depth: Int) -> Bool {
            guard depth <= 8, visited < 110 else { return false }
            visited += 1

            let role = axString(el, kAXRoleAttribute) ?? ""
            if role == (kAXButtonRole as String), isCloseButton(el) {
                if AXUIElementPerformAction(el, kAXPressAction as CFString) == .success {
                    return true
                }
            }

            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                for child in children {
                    if tryCloseButton(child, depth: depth + 1) { return true }
                }
            }
            return false
        }

        return tryCloseButton(root, depth: 0)
    }

    private func matchingCloseAction(on el: AXUIElement) -> String? {
        var namesRef: CFArray?
        guard AXUIElementCopyActionNames(el, &namesRef) == .success,
              let names = namesRef as? [String], !names.isEmpty else {
            return nil
        }
        // Prefer exact `"Name:Close"` / `"Close"` / `"AXCancel"` / `"AXClose"` before `"Clear"`.
        for name in names {
            let low = name.lowercased()
            if low == "axcancel" || low == "axclose" || low == "close" || low.contains("name:close\n") || low.hasPrefix("name:close") {
                return name
            }
        }
        for name in names {
            let low = name.lowercased()
            if low == "dismiss" || low.contains("name:dismiss") || low == "clear" || low.contains("name:clear\n") {
                return name
            }
        }
        return nil
    }

    private func isCloseButton(_ el: AXUIElement) -> Bool {
        let subrole = (axString(el, kAXSubroleAttribute) ?? "").lowercased()
        if subrole == "axclosebutton" { return true }
        let fields = [
            axString(el, kAXTitleAttribute),
            axString(el, kAXDescriptionAttribute),
            axString(el, kAXIdentifierAttribute),
            axString(el, kAXHelpAttribute),
        ].compactMap { $0?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }

        for f in fields {
            if f == "close" || f == "dismiss" || f == "clear" || f == "close notification"
                || f.contains("closebutton") || f.contains("close-button") || f.contains("dismiss") {
                return true
            }
        }
        return false
    }

    /// Collects live floating notification banner elements from `com.apple.notificationcenterui`,
    /// supporting BOTH macOS 15–27's full-screen overlay hosting `AXNotificationCenterBanner` /
    /// `AXNotificationCenterAlert` child groups AND compact floating banner windows, while
    /// ignoring the full Notification Center sidebar drawer.
    private func activeBannerElements(hintElement: AXUIElement) -> [AXUIElement] {
        guard watchedPID != 0 else { return [] }
        let appEl = AXUIElementCreateApplication(watchedPID)
        var windowsRef: CFTypeRef?
        let windows: [AXUIElement]
        if AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let list = windowsRef as? [AXUIElement], !list.isEmpty {
            windows = list
        } else {
            windows = [hintElement]
        }

        var found: [AXUIElement] = []

        for win in windows {
            // Skip the Notification Center sidebar drawer (contains widgets / "Edit Widgets").
            if windowContainsWidgetsOrDrawer(win) { continue }

            var bannerNodes: [AXUIElement] = []
            var visited = 0
            func findBanners(_ el: AXUIElement, depth: Int) {
                guard depth <= 12, visited < 220 else { return }
                visited += 1
                let sub = (axString(el, kAXSubroleAttribute) ?? "").lowercased()
                if sub == "axnotificationcenterbanner" || sub == "axnotificationcenteralert" {
                    bannerNodes.append(el)
                    return   // don't descend into an already-matched banner
                }
                var childrenRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                   let children = childrenRef as? [AXUIElement] {
                    for child in children { findBanners(child, depth: depth + 1) }
                }
            }
            findBanners(win, depth: 0)

            if !bannerNodes.isEmpty {
                found.append(contentsOf: bannerNodes)
            } else if isCompactBannerWindow(win) {
                found.append(win)
            }
        }
        return found
    }

    private func windowContainsWidgetsOrDrawer(_ win: AXUIElement) -> Bool {
        var visited = 0
        func scan(_ el: AXUIElement, depth: Int) -> Bool {
            guard depth <= 6, visited < 60 else { return false }
            visited += 1
            let sub = (axString(el, kAXSubroleAttribute) ?? "").lowercased()
            let title = (axString(el, kAXTitleAttribute) ?? "").lowercased()
            let desc = (axString(el, kAXDescriptionAttribute) ?? "").lowercased()
            if sub.contains("widget") || title == "edit widgets" || desc.contains("widget") {
                return true
            }
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                for child in children {
                    if scan(child, depth: depth + 1) { return true }
                }
            }
            return false
        }
        return scan(win, depth: 0)
    }

    private func isCompactBannerWindow(_ win: AXUIElement) -> Bool {
        var sizeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success,
           let axVal = sizeRef, CFGetTypeID(axVal) == AXValueGetTypeID() {
            var size = CGSize.zero
            if AXValueGetValue(axVal as! AXValue, .cgSize, &size) {
                return size.width >= 200 && size.width <= 540 && size.height >= 40 && size.height <= 320
            }
        }
        return false
    }

    private static let ignoredChromeStrings: Set<String> = [
        "options", "close", "clear", "clear all", "reply", "snooze", "show less",
        "show more", "now", "notification center", "banner", "alert", "actions",
    ]

    private func extractNotification(from root: AXUIElement) -> NotchNotification? {
        var texts: [String] = []
        var bannerDesc = ""
        var visited = 0

        func walk(_ el: AXUIElement, depth: Int) {
            guard depth < 10, visited < 90 else { return }
            visited += 1

            let role = axString(el, kAXRoleAttribute) ?? ""
            let subrole = axString(el, kAXSubroleAttribute) ?? ""
            if bannerDesc.isEmpty,
               (subrole.lowercased().contains("banner") || subrole.lowercased().contains("alert") || role == "AXGroup"),
               let desc = axString(el, kAXDescriptionAttribute), !desc.isEmpty {
                bannerDesc = desc
            }

            if role == (kAXStaticTextRole as String) {
                let candidate = (axString(el, kAXValueAttribute) ?? axString(el, kAXTitleAttribute) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty,
                   !Self.ignoredChromeStrings.contains(candidate.lowercased()),
                   !texts.contains(candidate) {
                    texts.append(candidate)
                }
            }

            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                for child in children {
                    walk(child, depth: depth + 1)
                }
            }
        }

        walk(root, depth: 0)
        // Drop short timestamp pills like "now", "1m ago", "2m"
        texts.removeAll { text in
            let l = text.lowercased()
            return l == "now" || l.hasSuffix("m ago") || l.hasSuffix("h ago") || l.hasSuffix("s ago")
        }
        guard !texts.isEmpty else { return nil }

        // Parse app name from AXDescription ("Messages, Maya Chen, Lunch at 1?") when available.
        var appName = ""
        if !bannerDesc.isEmpty {
            let parts = bannerDesc.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let first = parts.first, !first.isEmpty, first.count <= 40,
               !Self.ignoredChromeStrings.contains(first.lowercased()) {
                appName = first
            }
        }

        var remaining = texts
        if !appName.isEmpty, remaining.first?.caseInsensitiveCompare(appName) == .orderedSame {
            remaining.removeFirst()
        } else if appName.isEmpty, remaining.count >= 2 {
            // Check if the first text matches a known/running app name.
            let candidate = remaining[0]
            let resolved = AppIconCache.resolveBundleID(forAppName: candidate)
            if !resolved.hasPrefix("app.live.") {
                appName = candidate
                remaining.removeFirst()
            }
        }

        if appName.isEmpty { appName = "Notification" }
        guard !remaining.isEmpty else { return nil }

        let title = remaining[0]
        let subtitle: String
        let body: String
        if remaining.count >= 3 {
            subtitle = remaining[1]
            body = remaining.dropFirst(2).joined(separator: " ")
        } else if remaining.count == 2 {
            subtitle = ""
            body = remaining[1]
        } else {
            subtitle = ""
            body = ""
        }

        let bundleID = AppIconCache.resolveBundleID(forAppName: appName)
        if bundleID == Bundle.main.bundleIdentifier { return nil }

        return NotchNotification(
            id: "live.\(UUID().uuidString)",
            bundleID: bundleID,
            appName: AppIconCache.name(for: bundleID) == bundleID ? appName : AppIconCache.name(for: bundleID),
            title: title,
            subtitle: subtitle,
            body: body,
            date: Date()
        )
    }

    private func axString(_ el: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}

private func liveBannerAXCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let target = Unmanaged<LiveBannerObserver>.fromOpaque(refcon).takeUnretainedValue()
    target.scheduleScan(element: element)
}
