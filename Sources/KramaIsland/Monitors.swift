import AppKit
import ApplicationServices
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
    private var debounceWork: DispatchWorkItem?
    private var active: Set<String> = []
    private let queue = DispatchQueue(label: "KramaIsland.downloads", qos: .utility)
    private let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    private static let partialExtensions: Set<String> = ["crdownload", "download", "part", "partial"]

    func start() {
        let fd = Darwin.open(directory.path, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: queue)
            src.setEventHandler { [weak self] in self?.scheduleScan() }
            src.setCancelHandler { Darwin.close(fd) }
            src.resume()
            source = src
        }
        let t = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, !self.active.isEmpty else { return }
                self.scanOffMain()
            }
        }
        t.tolerance = 0.4
        timer = t
        queue.async { [weak self] in self?.scanOffMain() }
    }

    func stop() {
        source?.cancel(); source = nil
        timer?.invalidate(); timer = nil
        queue.async { [weak self] in
            self?.debounceWork?.cancel()
            self?.debounceWork = nil
        }
    }

    private func scheduleScan() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scanOffMain() }
        debounceWork = work
        queue.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func scanOffMain() {
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

        var updates: [LiveActivity] = []
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
            updates.append(LiveActivity(id: "dl.\(key)", kind: .download, symbol: "arrow.down.circle",
                                        title: name, subtitle: subtitle, progress: progress, tint: UI.info, duration: 0))
        }

        let stillThere = Set(partials.map(\.path))
        var completed: [(key: String, base: String, finishedPath: String?)] = []
        for key in active.subtracting(stillThere) {
            active.remove(key)
            let base = URL(fileURLWithPath: key).deletingPathExtension().lastPathComponent
            let finished = items.first(where: { $0.lastPathComponent == base })?.path
            completed.append((key, base, finished))
        }

        guard !updates.isEmpty || !completed.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for act in updates { self.onEvent?(act) }
            for done in completed {
                ActivityCenter.shared.dismiss(id: "dl.\(done.key)")
                guard let path = done.finishedPath else { continue }
                self.onEvent?(LiveActivity(
                    id: "dl.done.\(done.key)", kind: .download, symbol: "checkmark.circle.fill",
                    title: done.base, subtitle: "Download complete", progress: nil, tint: UI.success,
                    image: AppIconCache.fileIcon(for: path), duration: 4
                ))
                Feedback.tap()
            }
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

// MARK: - Visibility (hide over full-screen videos / full-screen apps / specific apps)

final class VisibilityMonitor {
    /// Reports the exact set of display IDs where KramaIsland should currently be hidden
    /// (e.g. a full-screen video on Monitor 1 hides Monitor 1 while keeping Monitor 2 visible!).
    var onHiddenDisplaysChange: ((Set<CGDirectDisplayID>) -> Void)?
    private var timer: Timer?
    private var lastHidden: Set<CGDirectDisplayID>?
    private var observers: [Any] = []
    private let evalQueue = DispatchQueue(label: "KramaIsland.visibility", qos: .utility)
    private var isEvaluating = false
    private var needsReevaluate = false

    private struct ScreenSnapshot {
        let displayID: CGDirectDisplayID
        let axScreen: CGRect
        let notchHeight: CGFloat
        let desktopReservesMenuBar: Bool
    }

    private struct EvalInput {
        let screens: [ScreenSnapshot]
        let frontPID: pid_t?
        let frontBundleID: String?
        let frontIsSelf: Bool
        let hideInFullscreen: Bool
        let hideInFullscreenMode: String
        let hiddenAppIDs: Set<String>
        let activeMediaBundleID: String?
    }

    /// Bundle ID prefixes / fragments treated as video & media players for "Videos & browsers only" mode.
    private static let videoAppHints: [String] = [
        "com.google.chrome", "com.apple.safari", "com.brave.browser", "com.microsoft.edgemac",
        "company.thebrowser", "com.vivaldi", "com.operasoftware", "org.mozilla.firefox",
        "org.chromium", "com.kagi.kagimacos", "ai.perplexity.comet", "com.apple.webkit",
        "org.videolan.vlc", "com.colliderli.iina", "com.apple.quicktimeplayerx", "com.apple.tv",
        "io.mpv", "com.firecore.infuse", "tv.plex", "com.eltima.elmedia", "com.movist",
        "com.apple.iwork.keynote", "com.microsoft.powerpoint", "us.zoom.xos", "com.apple.facetime",
        "com.hnc.discord", "ru.keepcoder.telegram", "net.whatsapp", "com.netflix", "com.disney",
    ]

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.evaluate() })
        observers.append(ws.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Re-check immediately and again after the macOS fullscreen Space animation settles.
            self?.evaluate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self?.evaluate() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.evaluate() })

        // Gentle 1.2s background fallback poll (instant transitions are driven by Space & App events).
        let t = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in self?.evaluate() }
        t.tolerance = 0.25
        timer = t
        evaluate()
    }

    deinit {
        timer?.invalidate()
        let ws = NSWorkspace.shared.notificationCenter
        for obs in observers {
            ws.removeObserver(obs)
            NotificationCenter.default.removeObserver(obs)
        }
    }

    func evaluate() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.evaluate() }
            return
        }
        if isEvaluating {
            needsReevaluate = true
            return
        }

        let settings = AppSettings.shared
        let screens = NotchGeometry.targetScreens
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let snapshots: [ScreenSnapshot] = screens.map { screen in
            let geo = NotchGeometry(screen: screen)
            let sf = screen.frame
            let ph = primaryHeight > 0 ? primaryHeight : sf.height
            let axScreen = CGRect(x: sf.minX, y: ph - sf.maxY, width: sf.width, height: sf.height)
            return ScreenSnapshot(
                displayID: screen.displayID,
                axScreen: axScreen,
                notchHeight: geo.hasNotch ? geo.notchHeight : 0,
                desktopReservesMenuBar: screen.visibleFrame.maxY < sf.maxY - 2
            )
        }
        let front = NSWorkspace.shared.frontmostApplication
        let activeMediaBundle = (IslandState.shared?.media?.isPlaying == true)
            ? IslandState.shared?.media?.player.bundleID.lowercased()
            : nil
        let input = EvalInput(
            screens: snapshots,
            frontPID: front?.processIdentifier,
            frontBundleID: front?.bundleIdentifier,
            frontIsSelf: front == NSRunningApplication.current,
            hideInFullscreen: settings.hideInFullscreen,
            hideInFullscreenMode: settings.hideInFullscreenMode,
            hiddenAppIDs: settings.hiddenAppIDs,
            activeMediaBundleID: activeMediaBundle
        )

        isEvaluating = true
        evalQueue.async { [weak self] in
            let hidden = Self.computeHiddenDisplays(input: input)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isEvaluating = false
                if hidden != self.lastHidden {
                    self.lastHidden = hidden
                    self.onHiddenDisplaysChange?(hidden)
                }
                if self.needsReevaluate {
                    self.needsReevaluate = false
                    self.evaluate()
                }
            }
        }
    }

    private static func computeHiddenDisplays(input: EvalInput) -> Set<CGDirectDisplayID> {
        var hidden = Set<CGDirectDisplayID>()
        let frontIsHiddenByList = !input.frontIsSelf
            && (input.frontBundleID.map { input.hiddenAppIDs.contains($0) } ?? false)

        if frontIsHiddenByList {
            for screen in input.screens { hidden.insert(screen.displayID) }
            return hidden
        }
        guard input.hideInFullscreen else { return hidden }

        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for screen in input.screens {
            if let fsApp = fullscreenApp(on: screen, windowList: list, frontPID: input.frontIsSelf ? nil : input.frontPID) {
                if input.hideInFullscreenMode == "video" {
                    if isVideoOrMediaApp(fsApp, activeMediaBundleID: input.activeMediaBundleID) {
                        hidden.insert(screen.displayID)
                    }
                } else {
                    hidden.insert(screen.displayID)
                }
            }
        }
        return hidden
    }

    private static func isVideoOrMediaApp(_ app: NSRunningApplication, activeMediaBundleID: String?) -> Bool {
        let bid = (app.bundleIdentifier ?? "").lowercased()
        let name = (app.localizedName ?? "").lowercased()
        if videoAppHints.contains(where: { bid.contains($0) }) { return true }
        if name.contains("video") || name.contains("player") || name.contains("youtube")
            || name.contains("netflix") || name.contains("tv") || name.contains("movie") {
            return true
        }
        if let activeMediaBundleID, activeMediaBundleID == bid {
            return true
        }
        return false
    }

    /// Detects whether ANY full-screen video or full-screen app is currently occupying `screen`.
    /// Runs strictly off the main thread and avoids cross-process AX IPC unless a full-size candidate
    /// window or missing Menu Bar actually exists on this display (zero system overhead at idle).
    private static func fullscreenApp(
        on screen: ScreenSnapshot,
        windowList list: [[String: Any]],
        frontPID: pid_t?
    ) -> NSRunningApplication? {
        let axScreen = screen.axScreen
        let notchH = screen.notchHeight
        let selfPID = ProcessInfo.processInfo.processIdentifier

        // Check whether the macOS Menubar window (layer 24) is currently drawn on this display.
        var hasVisibleMenuBar = false
        for w in list {
            let layer = (w[kCGWindowLayer as String] as? Int) ?? 0
            guard layer == 24 || layer == 25 else { continue }
            let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
            let name = (w[kCGWindowName as String] as? String) ?? ""
            guard owner == "Window Server" || name == "Menubar" else { continue }
            guard let bounds = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { continue }
            if abs(rect.minX - axScreen.minX) < 12,
               abs(rect.minY - axScreen.minY) < 12,
               rect.width >= axScreen.width * 0.85 {
                hasVisibleMenuBar = true
                break
            }
        }

        // Collect candidate large on-screen windows occupying this display.
        var candidatePIDs: [pid_t] = []
        var seenPIDs = Set<pid_t>()

        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != selfPID else { continue }
            let layer = (w[kCGWindowLayer as String] as? Int) ?? -1
            guard layer >= 0, layer < 25 else { continue }

            let ownerName = (w[kCGWindowOwnerName as String] as? String) ?? ""
            if ownerName == "Window Server" || ownerName == "WindowManager" || ownerName == "Dock"
                || ownerName == "Control Center" || ownerName == "Notification Center"
                || ownerName == "Wallpaper" {
                continue
            }

            guard let bounds = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { continue }

            let center = CGPoint(x: rect.midX, y: rect.midY)
            guard axScreen.contains(center),
                  rect.width >= axScreen.width - 10 else { continue }

            // Case 1: True edge-to-edge full-screen cover (including the menu bar strip at y = axScreen.minY).
            if rect.minY <= axScreen.minY + 4, rect.height >= axScreen.height - 6 {
                if let app = NSRunningApplication(processIdentifier: pid) {
                    return app
                }
            }

            // Case 2: Notched full-screen window (starts right below the notch bezel and extends to
            // the bottom of the display, e.g. 1512 × 950 at y = 32 on a 14" MacBook Pro).
            if rect.height >= axScreen.height - notchH - 12,
               rect.maxY >= axScreen.maxY - 6 {
                if seenPIDs.insert(pid).inserted {
                    candidatePIDs.append(pid)
                }
            }
        }

        // Fast zero-IPC exit: when Menu Bar is visible AND no full-size candidate exists, no AX IPC needed!
        guard !candidatePIDs.isEmpty || !hasVisibleMenuBar else { return nil }

        let axTrusted = AXIsProcessTrusted()
        for pid in candidatePIDs {
            guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
            if axTrusted, hasAXFullscreenWindow(pid: pid, on: axScreen) {
                return app
            }
            if !hasVisibleMenuBar && (screen.desktopReservesMenuBar || !axTrusted) {
                return app
            }
        }

        // Only check the frontmost external app via AXFullScreen when the Menu Bar is hidden on this display.
        if !hasVisibleMenuBar, axTrusted, let frontPID, !seenPIDs.contains(frontPID),
           let front = NSRunningApplication(processIdentifier: frontPID),
           hasAXFullscreenWindow(pid: frontPID, on: axScreen) {
            return front
        }

        return nil
    }

    /// True when `pid` owns an `AXFullScreen == true` window positioned on `axScreen`.
    private static func hasAXFullscreenWindow(pid: pid_t, on axScreen: CGRect) -> Bool {
        let appEl = AXUIElementCreateApplication(pid)
        var windowsToCheck: [AXUIElement] = []

        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
           let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() {
            windowsToCheck.append(focusedRef as! AXUIElement)
        }
        var listRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &listRef) == .success,
           let list = listRef as? [AXUIElement] {
            for w in list.prefix(4) { windowsToCheck.append(w) }
        }

        for win in windowsToCheck {
            var fsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &fsRef) == .success,
                  let isFS = fsRef as? Bool, isFS else { continue }

            // Confirm this fullscreen window is actually on KramaIsland's display (multi-monitor safe).
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
               AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success,
               let posRef, let sizeRef,
               CFGetTypeID(posRef) == AXValueGetTypeID(),
               CFGetTypeID(sizeRef) == AXValueGetTypeID() {
                var pt = CGPoint.zero
                var sz = CGSize.zero
                if AXValueGetValue(posRef as! AXValue, .cgPoint, &pt),
                   AXValueGetValue(sizeRef as! AXValue, .cgSize, &sz) {
                    let center = CGPoint(x: pt.x + sz.width / 2, y: pt.y + sz.height / 2)
                    if axScreen.contains(center) { return true }
                    continue
                }
            }
            return true
        }
        return false
    }
}
