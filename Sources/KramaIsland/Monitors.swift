import AppKit
import AVFoundation
import Combine
import CoreAudio
import IOBluetooth
import IOKit.ps
import SwiftUI

// MARK: - Battery (charger plugged in / unplugged, low battery)

final class BatteryWatcher {
    var onEvent: ((LiveActivity) -> Void)?
    var onChange: ((Battery.Info) -> Void)?
    private var source: CFRunLoopSource?
    private var last: Battery.Info?
    private var warned: Set<Int> = []
    private static weak var instance: BatteryWatcher?

    func start() {
        Self.instance = self
        let current = Battery.read()
        last = current
        onChange?(current)
        let callback: IOPowerSourceCallbackType = { _ in BatteryWatcher.instance?.changed() }
        if let src = IOPSNotificationCreateRunLoopSource(callback, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            source = src
        }
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        source = nil
    }

    private func changed() {
        let now = Battery.read()
        onChange?(now)
        defer { last = now }
        guard let was = last else { return }
        if was.onAC != now.onAC {
            onEvent?(LiveActivity(
                id: "battery.power", kind: .battery,
                symbol: now.onAC ? "bolt.fill" : "battery.75percent",
                title: now.onAC ? (now.percent >= 100 ? "Charged" : "Charging") : "On Battery",
                subtitle: "\(now.percent)%", progress: Double(now.percent) / 100,
                tint: now.onAC ? UI.success : .white, duration: 3.5))
        }
        if !now.onAC {
            for level in [20, 10, 5] where now.percent <= level && was.percent > level && !warned.contains(level) {
                warned.insert(level)
                onEvent?(LiveActivity(
                    id: "battery.low", kind: .battery, symbol: "battery.25percent",
                    title: "Low Battery", subtitle: "\(now.percent)% remaining",
                    progress: Double(now.percent) / 100, tint: UI.danger, duration: 7))
                Feedback.alert()
            }
        } else {
            warned.removeAll()
        }
    }
}

// MARK: - Mic / camera / Focus status

final class SystemStatus: ObservableObject {
    @Published private(set) var micInUse = false
    @Published private(set) var cameraInUse = false
    @Published private(set) var focusName: String?
    @Published private(set) var battery: Battery.Info = Battery.read()

    private var cameraObservation: NSKeyValueObservation?
    private var micDevice: AudioObjectID = 0
    private var focusTimer: Timer?
    private var started = false
    private let bgQueue = DispatchQueue(label: "KramaIsland.status", qos: .utility)

    private static let focusURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")

    func start() {
        guard !started else { return }
        started = true
        startMic()
        startCamera()
        refreshAsync()
        focusTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refreshAsync() }
    }

    func updateBattery(_ info: Battery.Info) {
        if info != battery { battery = info }
    }

    private func refreshAsync() {
        bgQueue.async { [weak self] in
            let b = Battery.read()
            var name: String?
            if let data = try? Data(contentsOf: Self.focusURL),
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let entries = json["data"] as? [[String: Any]] {
                for entry in entries {
                    guard let records = entry["storeAssertionRecords"] as? [[String: Any]], let first = records.first else { continue }
                    let details = first["assertionDetails"] as? [String: Any]
                    let identifier = details?["assertionDetailsModeIdentifier"] as? String ?? "com.apple.donotdisturb.mode.default"
                    name = Self.focusDisplayName(identifier)
                    break
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if b != self.battery { self.battery = b }
                if name != self.focusName { self.focusName = name }
            }
        }
    }

    // Microphone: CoreAudio tells us when the default input device is running "somewhere".
    private func startMic() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            self?.bindMicDevice()
        }
        bindMicDevice()
    }

    private func bindMicDevice() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
              dev != 0, dev != micDevice else { return }
        micDevice = dev
        var running = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(dev, &running, .main) { [weak self] _, _ in self?.readMic() }
        readMic()
    }

    private func readMic() {
        guard micDevice != 0 else { return }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(micDevice, &addr, 0, nil, &size, &value) == noErr else { return }
        let inUse = value != 0
        if inUse != micInUse { micInUse = inUse }
    }

    // Camera: AVFoundation exposes whether another app has the camera open.
    private func startCamera() {
        guard let device = AVCaptureDevice.default(for: .video) else { return }
        cameraObservation = device.observe(\.isInUseByAnotherApplication, options: [.initial, .new]) { [weak self] dev, _ in
            DispatchQueue.main.async {
                if self?.cameraInUse != dev.isInUseByAnotherApplication { self?.cameraInUse = dev.isInUseByAnotherApplication }
            }
        }
    }

    private static func focusDisplayName(_ identifier: String) -> String {
        let tail = identifier.components(separatedBy: ".").last ?? identifier
        switch tail.lowercased() {
        case "default": return "Do Not Disturb"
        case "sleep": return "Sleep"
        case "work": return "Work"
        case "personal": return "Personal"
        case "driving": return "Driving"
        case "fitness": return "Fitness"
        case "gaming": return "Gaming"
        case "mindfulness": return "Mindfulness"
        case "reading": return "Reading"
        default: return tail.prefix(1).uppercased() + tail.dropFirst()
        }
    }
}

// MARK: - Bluetooth (AirPods etc. connect, with per-bud battery)

final class BluetoothWatcher: NSObject {
    var onEvent: ((LiveActivity) -> Void)?
    private var connectNote: IOBluetoothUserNotification?

    func start() {
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self,
                                                 selector: #selector(deviceConnected(_:device:)))
    }

    func stop() {
        connectNote?.unregister()
        connectNote = nil
    }

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let name = device.name ?? "Bluetooth device"
        let key = device.addressString ?? name
        device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
        // Battery registry entries appear a moment after the link comes up.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            let battery = Self.batterySummary(for: name)
            let activity = LiveActivity(
                id: "bt.\(key)", kind: .bluetooth, symbol: Self.symbol(for: name),
                title: name, subtitle: battery ?? "Connected", progress: nil, tint: UI.info, duration: 5)
            DispatchQueue.main.async {
                self?.onEvent?(activity)
                Feedback.tap()
            }
        }
    }

    @objc private func deviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        note.unregister()
        let name = device.name ?? "Bluetooth device"
        onEvent?(LiveActivity(id: "bt.off.\(device.addressString ?? name)", kind: .bluetooth,
                              symbol: Self.symbol(for: name), title: name, subtitle: "Disconnected",
                              progress: nil, tint: UI.muted, duration: 3))
    }

    /// Reads BatteryPercentLeft/Right/Case (AirPods) or BatteryPercent (others) from the IO registry.
    static func batterySummary(for name: String) -> String? {
        for key in ["BatteryPercentLeft", "BatteryPercent"] {
            let xml = QuickSystem.run("/usr/sbin/ioreg", ["-r", "-k", key, "-a", "-l"])
            guard let data = xml.data(using: .utf8),
                  let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [Any]
            else { continue }
            var found: [String: Any]?
            func walk(_ node: Any) {
                guard found == nil else { return }
                if let dict = node as? [String: Any] {
                    if dict[key] != nil {
                        let product = (dict["Product"] as? String) ?? (dict["BluetoothName"] as? String) ?? ""
                        if product.isEmpty || name.isEmpty || product.localizedCaseInsensitiveContains(name)
                            || name.localizedCaseInsensitiveContains(product) {
                            found = dict
                            return
                        }
                    }
                    dict.values.forEach(walk)
                } else if let arr = node as? [Any] {
                    arr.forEach(walk)
                }
            }
            plist.forEach(walk)
            guard let d = found else { continue }
            if let l = d["BatteryPercentLeft"] as? Int, let r = d["BatteryPercentRight"] as? Int {
                var parts = ["L \(l)%", "R \(r)%"]
                if let c = d["BatteryPercentCase"] as? Int, c > 0 { parts.append("Case \(c)%") }
                return parts.joined(separator: " · ")
            }
            if let p = d["BatteryPercent"] as? Int { return "\(p)%" }
        }
        return nil
    }

    static func symbol(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("beats") { return "beats.headphones" }
        if n.contains("keyboard") { return "keyboard" }
        if n.contains("mouse") { return "magicmouse" }
        if n.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if n.contains("headphone") || n.contains("buds") { return "headphones" }
        return "dot.radiowaves.left.and.right"
    }
}

// MARK: - Downloads (Safari / Chrome / Finder partial files in ~/Downloads)

final class DownloadsWatcher {
    var onEvent: ((LiveActivity) -> Void)?
    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var active: Set<String> = []
    private let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    private static let partialExtensions: Set<String> = ["crdownload", "download", "part", "partial"]

    func start() {
        let fd = Darwin.open(directory.path, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: .main)
            src.setEventHandler { [weak self] in self?.scan() }
            src.setCancelHandler { Darwin.close(fd) }
            src.resume()
            source = src
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, !self.active.isEmpty else { return }
            self.scan()
        }
        scan()
    }

    func stop() {
        source?.cancel(); source = nil
        timer?.invalidate(); timer = nil
    }

    private func scan() {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else { return }
        // Only partials still being written to count; abandoned ".crdownload" leftovers from days
        // ago must not sit in the island as "Downloading…" forever.
        let partials = items.filter {
            Self.partialExtensions.contains($0.pathExtension.lowercased()) &&
            Date().timeIntervalSince(Self.lastModified($0)) < 120
        }

        for url in partials {
            let key = url.path
            let name = url.deletingPathExtension().lastPathComponent
            var progress: Double?
            var subtitle = "Downloading…"
            if url.pathExtension.lowercased() == "download",
               let data = try? Data(contentsOf: url.appendingPathComponent("Info.plist")),
               let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
               let total = (plist["DownloadEntryProgressTotalToLoad"] as? NSNumber)?.doubleValue, total > 0,
               let soFar = (plist["DownloadEntryProgressBytesSoFar"] as? NSNumber)?.doubleValue {
                progress = min(1, soFar / total)
                subtitle = "\(Int((progress ?? 0) * 100))% · \(ByteCountFormatter.string(fromByteCount: Int64(soFar), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))"
            } else {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > 0 { subtitle = "Downloading… \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))" }
            }
            active.insert(key)
            onEvent?(LiveActivity(id: "dl.\(key)", kind: .download, symbol: "arrow.down.circle",
                                  title: name, subtitle: subtitle, progress: progress, tint: UI.info, duration: 0))
        }

        let stillThere = Set(partials.map(\.path))
        for key in active.subtracting(stillThere) {
            active.remove(key)
            let base = URL(fileURLWithPath: key).deletingPathExtension().lastPathComponent
            ActivityCenter.shared.dismiss(id: "dl.\(key)")
            // Announce completion only when the finished file actually appeared (a partial that
            // merely went stale or was cancelled just disappears quietly).
            guard let finished = items.first(where: { $0.lastPathComponent == base }) else { continue }
            onEvent?(LiveActivity(id: "dl.done.\(key)", kind: .download, symbol: "checkmark.circle.fill",
                                  title: base, subtitle: "Download complete", progress: nil, tint: UI.success,
                                  image: NSWorkspace.shared.icon(forFile: finished.path), duration: 4))
            Feedback.tap()
        }
    }

    /// Modification time; for Safari's `.download` package, the newest file inside it.
    private static func lastModified(_ url: URL) -> Date {
        let own = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let inner = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        else { return own }
        return inner.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max().map { max($0, own) } ?? own
    }
}

// MARK: - Clipboard history (current boot session, auto-clears on shutdown)

final class ClipboardHistory: ObservableObject {
    struct Item: Identifiable, Equatable, Codable {
        let id: UUID
        let text: String
        let date: Date
        let sourceBundleID: String?
        let sourceAppName: String?

        init(id: UUID = UUID(), text: String, date: Date, sourceBundleID: String? = nil, sourceAppName: String? = nil) {
            self.id = id
            self.text = text
            self.date = date
            self.sourceBundleID = sourceBundleID
            self.sourceAppName = sourceAppName
        }

        var sourceIcon: NSImage? {
            sourceBundleID.map { AppIconCache.icon(for: $0) }
        }
    }

    private struct SessionArchive: Codable {
        let bootTime: Int64
        let items: [Item]
    }

    @Published private(set) var items: [Item] = []

    static let sessionURL = CustomActivityWatcher.directory.appendingPathComponent("clipboard-session.json")

    private var timer: Timer?
    private var lastCount = NSPasteboard.general.changeCount
    private var ignoreNext = false
    private var powerOffObserver: Any?
    private let ioQueue = DispatchQueue(label: "KramaIsland.clipboardIO", qos: .utility)

    init() {
        loadSessionIfSameBoot()
        powerOffObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard AppSettings.shared.clearClipboardOnShutdown else { return }
            self?.wipeForShutdown()
        }
    }

    deinit {
        if let powerOffObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(powerOffObserver)
        }
    }

    /// Exact Unix timestamp when this Mac booted (`kern.boottime`). If it changes, the Mac was
    /// shut down or restarted, so any leftover clipboard session file is automatically wiped.
    static func currentBootTime() -> Int64 {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return 0 }
        return Int64(tv.tv_sec)
    }

    func start() {
        guard timer == nil else { return }
        if items.isEmpty {
            captureCurrentPasteboard(recordFrontmost: false)
        }
        lastCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func poll() {
        pruneExpired()
        let pb = NSPasteboard.general
        guard pb.changeCount != lastCount else { return }
        lastCount = pb.changeCount
        if ignoreNext { ignoreNext = false; return }
        captureCurrentPasteboard(recordFrontmost: true)
    }

    private func captureCurrentPasteboard(recordFrontmost: Bool) {
        let pb = NSPasteboard.general
        // Password managers mark secrets as concealed/transient; never keep those.
        if let types = pb.types, types.contains(where: {
            $0.rawValue.contains("ConcealedType") || $0.rawValue.contains("TransientType")
        }) { return }
        guard let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.count <= 4000 else { return }
        let front = recordFrontmost ? NSWorkspace.shared.frontmostApplication : nil
        let bundle = (front != nil && front != NSRunningApplication.current) ? front?.bundleIdentifier : nil
        let appName = (front != nil && front != NSRunningApplication.current) ? front?.localizedName : nil
        items.removeAll { $0.text == text }
        items.insert(Item(text: text, date: Date(), sourceBundleID: bundle, sourceAppName: appName), at: 0)
        if items.count > 30 { items.removeLast(items.count - 30) }
        persistSession()
    }

    private func pruneExpired() {
        let minutes = AppSettings.shared.clipboardAutoClearMinutes
        guard minutes > 0, !items.isEmpty else { return }
        let cutoff = Date().addingTimeInterval(-Double(minutes) * 60)
        if items.contains(where: { $0.date < cutoff }) {
            items.removeAll { $0.date < cutoff }
            persistSession()
        }
    }

    /// Demo mode: replace the history with sample text and stop watching the pasteboard.
    func seed(_ texts: [String]) {
        stop()
        items = texts.enumerated().map {
            Item(text: $0.element, date: Date().addingTimeInterval(-Double($0.offset + 1) * 240))
        }
    }

    func copy(_ item: Item) {
        ignoreNext = true
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(item.text, forType: .string)
        lastCount = pb.changeCount
        items.removeAll { $0.id == item.id }
        items.insert(Item(id: item.id, text: item.text, date: Date(),
                          sourceBundleID: item.sourceBundleID, sourceAppName: item.sourceAppName), at: 0)
        persistSession()
        Feedback.tap()
    }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
        persistSession()
    }

    func clear() {
        items.removeAll()
        deleteSessionFile()
    }

    /// Called automatically when macOS shuts down, restarts, or logs out.
    func wipeForShutdown() {
        items.removeAll()
        try? FileManager.default.removeItem(at: Self.sessionURL)
        NSPasteboard.general.clearContents()
        NSLog("KramaIsland clipboard: cleared session clipboard for shutdown")
    }

    private func loadSessionIfSameBoot() {
        guard let data = try? Data(contentsOf: Self.sessionURL),
              let archive = try? JSONDecoder().decode(SessionArchive.self, from: data) else {
            return
        }
        let nowBoot = Self.currentBootTime()
        if AppSettings.shared.clearClipboardOnShutdown, nowBoot > 0, abs(archive.bootTime - nowBoot) > 2 {
            // Mac was shut down or restarted since this file was written — auto-wipe it.
            try? FileManager.default.removeItem(at: Self.sessionURL)
            items = []
            NSLog("KramaIsland clipboard: detected new boot session, cleared previous clipboard history")
            return
        }
        items = archive.items
        pruneExpired()
    }

    private func persistSession() {
        let snapshot = SessionArchive(bootTime: Self.currentBootTime(), items: items)
        ioQueue.async {
            try? FileManager.default.createDirectory(at: CustomActivityWatcher.directory, withIntermediateDirectories: true)
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: Self.sessionURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.sessionURL.path)
        }
    }

    private func deleteSessionFile() {
        ioQueue.async {
            try? FileManager.default.removeItem(at: Self.sessionURL)
        }
    }
}

// MARK: - Custom activities (Shortcuts / scripts)

/// Anything can push a live activity by writing JSON to
/// `~/Library/Application Support/KramaIsland/activity.json`, e.g. from a Shortcuts "Run Shell Script":
///   echo '{"title":"Build done","subtitle":"main · 42s","symbol":"hammer.fill","seconds":5}' > ".../activity.json"
/// Keys: title, subtitle, symbol (SF Symbol), progress (0–1), seconds (auto-dismiss), tint (hex).
final class CustomActivityWatcher {
    var onEvent: ((LiveActivity) -> Void)?
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/KramaIsland")
    static let fileURL = directory.appendingPathComponent("activity.json")
    private let queue = DispatchQueue(label: "KramaIsland.customActivity", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastModified: Date?

    func start() {
        queue.async { [self] in
            try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            lastModified = modified()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 1, repeating: 1.0)
            t.setEventHandler { [weak self] in self?.check() }
            t.resume()
            timer = t
        }
    }

    func stop() {
        queue.async { [self] in timer?.cancel(); timer = nil }
    }

    private func modified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: Self.fileURL.path))?[.modificationDate] as? Date
    }

    private func check() {
        let m = modified()
        guard m != lastModified else { return }
        lastModified = m
        guard let m, let data = try? Data(contentsOf: Self.fileURL),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let title = json["title"] as? String, !title.isEmpty else { return }
        let tint = (json["tint"] as? String).flatMap { Color(hex: $0) } ?? Theme.accent
        let event = LiveActivity(
            id: "custom.\(m.timeIntervalSince1970)", kind: .custom,
            symbol: json["symbol"] as? String ?? "sparkles",
            title: title, subtitle: json["subtitle"] as? String ?? "",
            progress: (json["progress"] as? NSNumber)?.doubleValue,
            tint: tint, duration: (json["seconds"] as? NSNumber)?.doubleValue ?? 5)
        DispatchQueue.main.async { self.onEvent?(event) }
    }
}

// MARK: - Visibility (hide over full-screen apps / specific apps)

final class VisibilityMonitor {
    var onChange: ((Bool) -> Void)?
    private var timer: Timer?
    private var last: Bool?
    private var observer: Any?

    func start() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.evaluate() }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.evaluate() }
        evaluate()
    }

    func evaluate() {
        let settings = AppSettings.shared
        var visible = true
        if let app = NSWorkspace.shared.frontmostApplication, app != NSRunningApplication.current {
            if let bundleID = app.bundleIdentifier, settings.hiddenAppIDs.contains(bundleID) {
                visible = false
            } else if settings.hideInFullscreen, Self.isFullscreen(pid: app.processIdentifier) {
                visible = false
            }
        }
        if visible != last {
            last = visible
            onChange?(visible)
        }
    }

    /// True when the app owns a normal-layer window covering the notched screen.
    static func isFullscreen(pid: pid_t) -> Bool {
        let screen = NotchGeometry.current.screen.frame
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return false }
        for window in list {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { continue }
            if abs(rect.width - screen.width) < 2, abs(rect.height - screen.height) < 2 { return true }
        }
        return false
    }
}
