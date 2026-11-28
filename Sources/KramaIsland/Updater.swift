import AppKit
import Combine
import Security

/// A published GitHub release, as far as the island cares.
struct AppRelease: Equatable {
    let version: String          // "1.5.0": normalized dotted version
    let title: String            // "KramaIsland 1.5.0"
    let notes: String            // the release notes, Markdown
    let pageURL: URL
    let dmgURL: URL?
    let dmgSize: Int64
    let publishedAt: Date?

    /// Parses GitHub's `releases/latest` JSON. Nil for a draft or anything without a version.
    static func parse(_ data: Data) -> AppRelease? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, !tag.isEmpty,
              json["draft"] as? Bool != true else { return nil }

        let rawName = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Extract dotted semver from tag first ("v1.5.0", "1.5.0"), falling back to release title ("V 1.5.0").
        let version = extractVersion(from: tag)
            ?? extractVersion(from: rawName)
            ?? (tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()).trimmingCharacters(in: .whitespaces) : tag)

        let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? Updater.releasesPage
        var dmgURL: URL?
        var size: Int64 = 0
        let assets = json["assets"] as? [[String: Any]] ?? []
        // Prefer an asset named KramaIsland*.dmg, otherwise any .dmg asset.
        let sortedAssets = assets.sorted { a, b in
            let na = ((a["name"] as? String) ?? "").lowercased()
            let nb = ((b["name"] as? String) ?? "").lowercased()
            return na.contains("kramaisland") && !nb.contains("kramaisland")
        }
        for asset in sortedAssets {
            guard let name = asset["name"] as? String, name.lowercased().hasSuffix(".dmg"),
                  let link = asset["browser_download_url"] as? String, let url = URL(string: link) else { continue }
            dmgURL = url
            size = (asset["size"] as? NSNumber)?.int64Value ?? 0
            break
        }
        let published = (json["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return AppRelease(
            version: version,
            title: rawName.isEmpty ? "KramaIsland \(version)" : rawName,
            notes: json["body"] as? String ?? "",
            pageURL: page,
            dmgURL: dmgURL,
            dmgSize: size,
            publishedAt: published
        )
    }

    /// Extracts a dotted version like `1.5.0` or `1.5` from strings such as `v1.5.0`, `V 1.5.0`, or `Release 1.5.2`.
    static func extractVersion(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\d+(?:\.\d+)+"#) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: match.range)
    }
}

/// Dotted version strings: "1.10.0" is newer than "1.9.2"; missing or non-numeric parts count as 0.
enum Version {
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private static func parts(_ s: String) -> [Int] {
        s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
}

/// Checks GitHub Releases for a newer KramaIsland, alerts the user cleanly via the Dynamic Island
/// and a native Update Alert sheet, and installs signature-verified updates in place.
///
/// Uses HTTP `If-None-Match` (`ETag`) conditional requests so GitHub replies `304 Not Modified`
/// with zero rate-limit cost whenever no new version has been published. This allows checking on
/// every launch, on Mac wake, and every 2 hours while sending zero user or device telemetry.
final class Updater: ObservableObject {
    static let shared = Updater()

    static let repo = "Seavik2142/KramaIsland"
    static let releasesPage = URL(string: "https://github.com/\(repo)/releases")!
    /// `KRAMAISLAND_UPDATE_FEED=<url>` points the checker at another JSON (a `file://` one for tests).
    static let feedURL: URL = {
        if let s = ProcessInfo.processInfo.environment["KRAMAISLAND_UPDATE_FEED"], let u = URL(string: s) { return u }
        return URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    }()
    static let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    static let checkInterval: TimeInterval = 2 * 3600           // re-check every 2 h using ETag (304 = 0 rate-limit cost)
    private static let wakeMinInterval: TimeInterval = 30 * 60  // avoid hammering on rapid lid open/close
    private static let remindLaterCooldown: TimeInterval = 12 * 3600

    enum Phase: Equatable {
        case idle
        case checking
        case downloading(Double)     // 0…1
        case installing
        case relaunching
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .checking, .downloading, .installing, .relaunching: return true
            case .idle, .failed: return false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    /// The newest published release GitHub reported (cached across launches).
    @Published private(set) var latest: AppRelease?
    @Published private(set) var lastChecked: Date?
    /// Non-nil only during an interactive "Preview Update Alert" test from Settings.
    @Published var previewRelease: AppRelease?

    private let settings = AppSettings.shared
    private let persist = ProcessInfo.processInfo.environment["KRAMAISLAND_UPDATE_FEED"] == nil
    private let queue = DispatchQueue(label: "KramaIsland.updater", qos: .utility)
    private var timer: Timer?
    private var wakeObserver: Any?
    private var progressObservation: NSKeyValueObservation?
    private var announcedHUD: Set<String> = []
    private var remindedLaterThisSession: Set<String> = []
    private static let cacheKey = "updatesLatestJSON"
    private static let etagKey = "updatesLatestETag"

    init() {
        if persist, let data = UserDefaults.standard.data(forKey: Self.cacheKey) {
            latest = AppRelease.parse(data)
            let t = settings.updatesLastCheck
            lastChecked = t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
    }

    deinit {
        timer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    // MARK: - State

    /// A release newer than this build, skipped by the user or not (Settings shows it either way).
    var newer: AppRelease? {
        guard let latest, Version.compare(latest.version, Self.currentVersion) == .orderedDescending else { return nil }
        return latest
    }

    /// A newer release the user has not skipped: what the island, alert, shade, and menu announce.
    var available: AppRelease? {
        guard let newer, newer.version != settings.updatesSkippedVersion else { return nil }
        return newer
    }

    /// Either a real available update or an active Settings preview release.
    var activeAlertRelease: AppRelease? {
        available ?? previewRelease
    }

    var isSkipped: Bool { newer.map { $0.version == settings.updatesSkippedVersion } ?? false }

    /// In-place install needs a bundle signed with a real certificate: the download is checked
    /// against this copy's designated requirement, which an ad-hoc or unsigned build cannot satisfy.
    var canInstall: Bool {
        Permissions.isBundled
            && Permissions.codeIdentity != "unsigned"
            && !Permissions.codeIdentity.contains("cdhash")
    }

    func skip(_ skipped: Bool) {
        if previewRelease != nil {
            previewRelease = nil
            ActivityCenter.shared.dismiss(id: "update")
            UpdateAlertWindowController.shared.close()
            return
        }
        settings.updatesSkippedVersion = skipped ? (newer?.version ?? "") : ""
        if skipped {
            ActivityCenter.shared.dismiss(id: "update")
            UpdateAlertWindowController.shared.close()
        }
        objectWillChange.send()
    }

    func remindLater(for version: String) {
        if previewRelease?.version == version {
            previewRelease = nil
        } else {
            remindedLaterThisSession.insert(version)
            settings.updatesLastAlertedVersion = version
            settings.updatesLastAlertTime = Date().timeIntervalSince1970
        }
        ActivityCenter.shared.dismiss(id: "update")
        UpdateAlertWindowController.shared.close()
    }

    func openReleasePage() {
        NSWorkspace.shared.open(newer?.pageURL ?? latest?.pageURL ?? Self.releasesPage)
    }

    // MARK: - Checking (Launch + Wake + Periodic ETag)

    /// Checks on launch, after waking from sleep, and every 2 hours via lightweight ETag requests.
    /// Previews and demo runs stay offline unless a test feed is explicitly configured.
    func startSchedule() {
        let env = ProcessInfo.processInfo.environment
        if env["KRAMAISLAND_UPDATE_FEED"] == nil, env["KRAMAISLAND_PREVIEW"] != nil || env["KRAMAISLAND_DEMO"] == "1" { return }

        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            self?.checkIfDue()
        }
        t.tolerance = 300
        timer = t

        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                    self?.checkAfterWake()
                }
            }
        }

        // Fresh launch check using ETag (304 Not Modified costs 0 GitHub rate-limit quota).
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.settings.updatesAutoCheck else { return }
            self.check(manual: false)
        }
    }

    private func checkAfterWake() {
        guard settings.updatesAutoCheck else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.wakeMinInterval { return }
        check(manual: false)
    }

    private func checkIfDue() {
        guard settings.updatesAutoCheck else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.checkInterval {
            announceIfNeeded()
            return
        }
        check(manual: false)
    }

    /// Asks GitHub for the latest release. Uses `If-None-Match` ETag when cached so unchanged checks
    /// return `304 Not Modified` cleanly with zero quota usage.
    func check(manual: Bool) {
        guard !phase.isBusy else { return }
        phase = .checking
        var request = URLRequest(url: Self.feedURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("KramaIsland/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        if persist, !manual, let etag = UserDefaults.standard.string(forKey: Self.etagKey), !etag.isEmpty, latest != nil {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async { self?.finishCheck(manual: manual, data: data, response: response, error: error) }
        }.resume()
    }

    private func finishCheck(manual: Bool, data: Data?, response: URLResponse?, error: Error?) {
        if let error {
            phase = manual ? .failed("Could not reach GitHub: \(error.localizedDescription)") : .idle
            return
        }
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 304 {
                // Release hasn't changed on GitHub — cached release is still authoritative (0 quota used).
                lastChecked = Date()
                if persist { settings.updatesLastCheck = lastChecked?.timeIntervalSince1970 ?? 0 }
                phase = .idle
                if !manual { announceIfNeeded() }
                return
            }
            if http.statusCode == 404 {
                phase = manual ? .failed("No published GitHub release found yet.") : .idle
                return
            }
            if http.statusCode != 200 {
                let message = http.statusCode == 403 || http.statusCode == 429
                    ? "GitHub is limiting requests from this network. Try again in an hour."
                    : "GitHub answered with status \(http.statusCode)."
                phase = manual ? .failed(message) : .idle
                return
            }
            if persist, let etag = http.value(forHTTPHeaderField: "ETag"), !etag.isEmpty {
                UserDefaults.standard.set(etag, forKey: Self.etagKey)
            }
        }
        guard let data, let release = AppRelease.parse(data) else {
            phase = manual ? .failed("Could not read the release details from GitHub.") : .idle
            return
        }
        latest = release
        lastChecked = Date()
        if persist {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
            settings.updatesLastCheck = lastChecked?.timeIntervalSince1970 ?? 0
        }
        phase = .idle
        if manual {
            if let newer {
                UpdateAlertWindowController.shared.show(release: newer, isPreview: false)
            }
        } else {
            announceIfNeeded()
        }
        // Developer aid: KRAMAISLAND_UPDATE_INSTALL=1 installs whatever a (test) feed offers, no click needed.
        if ProcessInfo.processInfo.environment["KRAMAISLAND_UPDATE_INSTALL"] == "1", newer != nil { install() }
    }

    // MARK: - User Update Alerts

    /// Announces an available update via:
    /// 1. Interactive Dynamic Island HUD (with one-click `Update` button & subtle alert feedback).
    /// 2. Floating native macOS Update Alert window (once per new version / after Remind Later cooldown).
    private func announceIfNeeded() {
        guard Permissions.isBundled, let release = available else { return }
        let isQuiet = IslandState.shared?.isQuiet ?? false

        if settings.updatesNotify, !announcedHUD.contains(release.version) {
            announcedHUD.insert(release.version)
            presentIslandUpdateHUD(for: release)
            if !isQuiet { Feedback.alert() }
        }

        if settings.updatesShowAlert, !isQuiet, shouldShowAlertWindow(for: release.version) {
            settings.updatesLastAlertedVersion = release.version
            settings.updatesLastAlertTime = Date().timeIntervalSince1970
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                UpdateAlertWindowController.shared.show(release: release, isPreview: false)
            }
        }
    }

    private func shouldShowAlertWindow(for version: String) -> Bool {
        guard !remindedLaterThisSession.contains(version) else { return false }
        if settings.updatesLastAlertedVersion != version { return true }
        let elapsed = Date().timeIntervalSince1970 - settings.updatesLastAlertTime
        return elapsed >= Self.remindLaterCooldown
    }

    private func presentIslandUpdateHUD(for release: AppRelease) {
        let subtitle = canInstall && release.dmgURL != nil
            ? "Click Update to install & relaunch"
            : "Click to view release notes & download"
        ActivityCenter.shared.show(LiveActivity(
            id: "update",
            kind: .update,
            symbol: "arrow.down.circle.fill",
            title: "KramaIsland \(release.version) Available",
            subtitle: subtitle,
            progress: nil,
            tint: UI.info,
            image: BrandIcon.image,
            duration: 18
        ))
    }

    /// Triggers a live preview of both the Dynamic Island Update HUD and the native Update Alert
    /// window so you can see exactly what users see when you publish a new release.
    func previewUpdateAlert() {
        let nextVer = Self.nextMinorVersion(from: Self.currentVersion)
        let sample = AppRelease(
            version: nextVer,
            title: "KramaIsland \(nextVer)",
            notes: """
            ### What's New
            - Instant drag-to-AirDrop notch zone with zero Finder lag
            - Multi-display Dynamic Island support across all connected monitors
            - Automatic full-screen video hiding & smoother 120 fps spring physics
            - Signature-verified one-click updates that keep all macOS permissions
            """,
            pageURL: Self.releasesPage,
            dmgURL: nil,
            dmgSize: 3_600_000,
            publishedAt: Date()
        )
        previewRelease = sample
        presentIslandUpdateHUD(for: sample)
        Feedback.alert()
        UpdateAlertWindowController.shared.show(release: sample, isPreview: true)
    }

    private static func nextMinorVersion(from current: String) -> String {
        let nums = current.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let major = nums.count > 0 ? nums[0] : 1
        let minor = (nums.count > 1 ? nums[1] : 0) + 1
        return "\(major).\(minor).0"
    }

    /// Called when the user clicks the primary action on the Dynamic Island Update HUD or Hover row.
    func triggerPrimaryUpdateAction() {
        ActivityCenter.shared.dismiss(id: "update")
        if let preview = previewRelease {
            UpdateAlertWindowController.shared.show(release: preview, isPreview: true)
            return
        }
        guard let release = newer else {
            SettingsWindowController.shared.show(tab: "updates")
            return
        }
        UpdateAlertWindowController.shared.show(release: release, isPreview: false)
        if canInstall && release.dmgURL != nil {
            install()
        }
    }

    // MARK: - Installing

    /// Download → verify → swap → relaunch. Shows live progress in both the Update Alert / Settings
    /// window and the Dynamic Island, and falls back to opening the DMG in Finder if read-only.
    func install() {
        guard !phase.isBusy, let release = newer else { return }
        guard canInstall, let dmgURL = release.dmgURL else { openReleasePage(); return }

        ActivityCenter.shared.dismiss(id: "update")
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("KramaIsland-update-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        } catch {
            phase = .failed("Could not create a temporary folder: \(error.localizedDescription)")
            return
        }

        phase = .downloading(0)
        publishProgressActivity(title: "Downloading v\(release.version)…", subtitle: "Starting download", progress: 0.02)

        var request = URLRequest(url: dmgURL)
        request.setValue("KramaIsland/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120
        let task = URLSession.shared.downloadTask(with: request) { [weak self] tmp, response, error in
            guard let self else { return }
            if let error { self.fail("Download failed: \(error.localizedDescription)"); return }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                self.fail("Download failed: GitHub answered with status \(http.statusCode)."); return
            }
            guard let tmp else { self.fail("Download failed."); return }
            let dmg = work.appendingPathComponent("KramaIsland.dmg")
            do { try FileManager.default.moveItem(at: tmp, to: dmg) } catch {
                self.fail("Could not keep the download: \(error.localizedDescription)"); return
            }
            DispatchQueue.main.async {
                self.phase = .installing
                self.publishProgressActivity(
                    title: "Installing v\(release.version)…",
                    subtitle: "Verifying signature & updating app",
                    progress: nil
                )
            }
            self.queue.async { self.installDMG(dmg, work: work, release: release) }
        }
        progressObservation = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            let fraction = max(0, min(1, progress.fractionCompleted))
            DispatchQueue.main.async {
                guard let self, case .downloading = self.phase else { return }
                self.phase = .downloading(fraction)
                self.publishProgressActivity(
                    title: "Downloading v\(release.version)…",
                    subtitle: "\(Int((fraction * 100).rounded()))%",
                    progress: fraction
                )
            }
        }
        task.resume()
    }

    private func publishProgressActivity(title: String, subtitle: String, progress: Double?) {
        ActivityCenter.shared.show(LiveActivity(
            id: "update.progress",
            kind: .update,
            symbol: "arrow.down.circle.fill",
            title: title,
            subtitle: subtitle,
            progress: progress,
            tint: UI.info,
            duration: 0
        ))
    }

    private func installDMG(_ dmg: URL, work: URL, release: AppRelease) {
        let fm = FileManager.default
        let mount = work.appendingPathComponent("mnt", isDirectory: true)
        try? fm.createDirectory(at: mount, withIntermediateDirectories: true)
        let attach = Self.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen",
                                                   "-mountpoint", mount.path, "-quiet"])
        let newApp = mount.appendingPathComponent("KramaIsland.app")
        guard attach.status == 0, fm.fileExists(atPath: newApp.path) else {
            _ = Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"])
            try? fm.removeItem(at: work)
            fail("The disk image could not be opened" + (attach.output.isEmpty ? "." : ": \(attach.output)"))
            return
        }

        if let problem = Self.verify(newApp) {
            _ = Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"])
            try? fm.removeItem(at: work)
            fail(problem)
            return
        }

        let current = Bundle.main.bundleURL
        let folder = current.deletingLastPathComponent()
        let staged = folder.appendingPathComponent(".KramaIsland-\(release.version).app")
        let previous = folder.appendingPathComponent(".KramaIsland-previous.app")
        try? fm.removeItem(at: staged)
        try? fm.removeItem(at: previous)

        // Copy next to the destination first so the swap itself is two atomic renames on one volume.
        let copy = Self.run("/usr/bin/ditto", [newApp.path, staged.path])
        guard copy.status == 0 else {
            try? fm.removeItem(at: staged)
            manualFallback("KramaIsland could not write into \(folder.path)" + (copy.output.isEmpty ? "." : " (\(copy.output))."),
                           dmg: dmg, mount: mount)
            return
        }
        do {
            try fm.moveItem(at: current, to: previous)
        } catch {
            try? fm.removeItem(at: staged)
            manualFallback("KramaIsland could not replace itself in \(folder.path): \(error.localizedDescription).",
                           dmg: dmg, mount: mount)
            return
        }
        do {
            try fm.moveItem(at: staged, to: current)
        } catch {
            try? fm.moveItem(at: previous, to: current)
            try? fm.removeItem(at: staged)
            manualFallback("KramaIsland could not move the new version into place: \(error.localizedDescription).",
                           dmg: dmg, mount: mount)
            return
        }
        _ = Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", current.path])
        _ = Self.run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                     ["-f", current.path])
        if (try? fm.removeItem(at: previous)) == nil {
            try? fm.trashItem(at: previous, resultingItemURL: nil)
        }
        _ = Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"])
        try? fm.removeItem(at: work)
        NSLog("KramaIsland updater: installed %@ at %@, relaunching", release.version, current.path)

        DispatchQueue.main.async {
            self.phase = .relaunching
            ActivityCenter.shared.dismiss(id: "update.progress")
            ActivityCenter.shared.show(LiveActivity(
                id: "update.done",
                kind: .update,
                symbol: "checkmark.circle.fill",
                title: "Updated to v\(release.version)",
                subtitle: "Relaunching KramaIsland…",
                progress: nil,
                tint: UI.success,
                duration: 4
            ))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { QuickSystem.relaunch() }
        }
    }

    /// The app in the DMG must satisfy this copy's designated requirement: same bundle id, same
    /// certificate. That is what macOS keys permission grants to, and what stops a swapped binary.
    private static func verify(_ app: URL) -> String? {
        let byHand = " Open the release page and install it by hand."
        var newCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &newCode) == errSecSuccess, let newCode else {
            return "The downloaded app could not be read." + byHand
        }
        var selfCode: SecCode?
        var selfStatic: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
              SecCodeCopyStaticCode(selfCode, [], &selfStatic) == errSecSuccess, let selfStatic,
              SecCodeCopyDesignatedRequirement(selfStatic, [], &requirement) == errSecSuccess, let requirement else {
            return "This copy's own signature could not be read, so the download was not verified." + byHand
        }
        var errors: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(newCode, SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
                                                          requirement, &errors)
        guard status == errSecSuccess else {
            let detail = errors?.takeRetainedValue().localizedDescription ?? "status \(status)"
            return "The download is not signed with the same certificate as this copy (\(detail)), so it was not installed." + byHand
        }
        return nil
    }

    /// Leaves the DMG mounted and visible in Finder so the user can drag the app over by hand.
    private func manualFallback(_ reason: String, dmg: URL, mount: URL) {
        _ = Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"])
        _ = Self.run("/usr/bin/hdiutil", ["attach", dmg.path])
        fail(reason + " The disk image is open in Finder: drag KramaIsland into Applications to replace this copy, then relaunch.")
    }

    private func fail(_ message: String) {
        NSLog("KramaIsland updater: %@", message)
        DispatchQueue.main.async {
            ActivityCenter.shared.dismiss(id: "update.progress")
            self.phase = .failed(message)
        }
    }

    private static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }
}
