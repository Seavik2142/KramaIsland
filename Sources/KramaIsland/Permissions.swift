import AppKit
import ApplicationServices
import AVFoundation
import CoreBluetooth
import EventKit
import Security

extension Notification.Name {
    /// Posted on the main thread after `tccutil reset`: modules drop cached "declined" state and look again.
    static let notchPermissionsReset = Notification.Name("KramaIsland.permissionsReset")
    /// Posted when the user clears local caches/history from Settings ▸ Privacy.
    static let notchClearLocalData = Notification.Name("KramaIsland.clearLocalData")
}

/// A macOS privacy grant KramaIsland uses.
///
/// macOS ties every grant (Accessibility, Full Disk Access, Calendar, Camera, Bluetooth, Automation…)
/// to the code signature of the build that asked for it. A build with a different signature fails
/// that check: System Settings keeps showing the switch on, yet the app cannot use it. Removing the
/// stale entry (`tccutil reset`) lets macOS ask cleanly again; see `Permissions.repair`.
enum Permission: String, CaseIterable, Identifiable {
    case accessibility, fullDiskAccess, calendar, camera, bluetooth

    var id: String { rawValue }

    /// Core desktop permissions shown prominently in the primary card.
    static let coreCases: [Permission] = [.accessibility, .fullDiskAccess, .calendar]
    /// Hardware permissions requested on demand when first used.
    static let hardwareCases: [Permission] = [.camera, .bluetooth]

    /// Service name as `tccutil` expects it.
    var tccService: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .fullDiskAccess: return "SystemPolicyAllFiles"
        case .calendar: return "Calendar"
        case .camera: return "Camera"
        case .bluetooth: return "BluetoothAlways"
        }
    }

    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .fullDiskAccess: return "Full Disk Access"
        case .calendar: return "Calendar"
        case .camera: return "Camera"
        case .bluetooth: return "Bluetooth"
        }
    }

    var symbol: String {
        switch self {
        case .accessibility: return "accessibility"
        case .fullDiskAccess: return "internaldrive.fill"
        case .calendar: return "calendar"
        case .camera: return "camera.fill"
        case .bluetooth: return "airpodspro"
        }
    }

    var purpose: String {
        switch self {
        case .accessibility: return "Global ⌥ Space hotkey, replaces the native macOS volume HUD, window snapping, and browser media keys."
        case .fullDiskAccess: return "Reads Notification Center's local database to mirror alerts on-device."
        case .calendar: return "Displays your next upcoming meeting and one-click Join link."
        case .camera: return "Powers the quick on-demand Camera Mirror check inside the shade."
        case .bluetooth: return "Detects AirPods and Bluetooth devices connecting with battery levels."
        }
    }

    var pane: String {
        switch self {
        case .accessibility: return PrivacyPane.accessibility
        case .fullDiskAccess: return PrivacyPane.fullDiskAccess
        case .calendar: return PrivacyPane.calendars
        case .camera: return PrivacyPane.camera
        case .bluetooth: return PrivacyPane.bluetooth
        }
    }

    /// Whether macOS can show a direct system consent prompt for this permission.
    var hasPrompt: Bool {
        switch self {
        case .accessibility, .calendar, .camera: return true
        case .fullDiskAccess, .bluetooth: return false
        }
    }
}

enum Grant: Equatable {
    case granted
    case denied
    case notAsked      // macOS has never prompted yet
    case unknown       // nothing to test against yet (e.g. no notification store on this Mac)

    var isGranted: Bool { self == .granted }
}

enum Permissions {
    static let bundleID = "com.kramaisland.app"

    /// What a row shows: current grant state, and whether a previously granted permission became stale.
    struct Status: Equatable {
        var grant: Grant
        var stale: Bool
        var isGranted: Bool { grant.isGranted }
    }

    /// Running as KramaIsland.app (grants keyed by bundle id) rather than a bare `swift run` binary.
    static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Hook for the Calendar prompt, set by the owner of the live `CalendarModule`.
    static var calendarRequest: (() -> Void)?

    // MARK: Reading

    static func check(_ p: Permission) -> Grant {
        switch p {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .denied
        case .fullDiskAccess:
            switch NotificationWatcher.storeAccess() {
            case .ok: return .granted
            case .needsFullDiskAccess: return .denied
            case .missing, .failed: return .unknown
            }
        case .calendar:
            let s = EKEventStore.authorizationStatus(for: .event)
            switch s {
            case .notDetermined: return .notAsked
            case .authorized: return .granted
            default:
                if #available(macOS 14, *), s == .fullAccess { return .granted }
                return .denied
            }
        case .camera:
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: return .granted
            case .notDetermined: return .notAsked
            default: return .denied
            }
        case .bluetooth:
            switch CBManager.authorization {
            case .allowedAlways: return .granted
            case .notDetermined: return .notAsked
            default: return .denied
            }
        }
    }

    /// Reads a permission and remembers the answer, so a grant that disappears is reported as stale.
    static func status(_ p: Permission) -> Status {
        let grant = check(p)
        let d = UserDefaults.standard
        switch grant {
        case .granted:
            if !d.bool(forKey: grantedKey(p)) { d.set(true, forKey: grantedKey(p)) }
            if d.object(forKey: staleKey(p)) != nil { d.removeObject(forKey: staleKey(p)) }
            return Status(grant: grant, stale: false)
        case .denied:
            if d.bool(forKey: grantedKey(p)) {
                if !d.bool(forKey: staleKey(p)) { d.set(true, forKey: staleKey(p)) }
                return Status(grant: grant, stale: true)
            }
            return Status(grant: grant, stale: d.bool(forKey: staleKey(p)))
        case .notAsked, .unknown:
            return Status(grant: grant, stale: false)
        }
    }

    private static func grantedKey(_ p: Permission) -> String { "permissions.granted.\(p.rawValue)" }
    private static func staleKey(_ p: Permission) -> String { "permissions.stale.\(p.rawValue)" }
    private static let identityKey = "permissions.identity"

    // MARK: Code identity

    /// The designated requirement macOS stores with every grant, e.g.
    /// `identifier "com.kramaisland.app" and certificate root = H"…"` for a release, or
    /// `cdhash H"…"` for an ad-hoc build (different after every compile).
    static let codeIdentity: String = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return "unsigned" }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return "unsigned" }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
              let requirement else { return "unsigned" }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return "unsigned" }
        return text as String
    }()

    /// Common name of the signing certificate, if any ("KramaIsland Developer", "Developer ID Application: …").
    static let signerName: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certs.first else { return nil }
        return SecCertificateCopySubjectSummary(leaf) as String?
    }()

    /// One line for Settings ▸ About: who signed this build and what that means for grants.
    static var identitySummary: String {
        if codeIdentity.contains("Developer ID Application") {
            return "Signed with \(signerName ?? "a Developer ID") · grants survive updates"
        }
        if codeIdentity.contains("certificate root") || codeIdentity.contains("certificate leaf") {
            return "Signed with the \(signerName ?? "project") certificate · grants survive updates"
        }
        if codeIdentity.contains("cdhash") {
            return "Ad-hoc signature · macOS sees every build as a new app, so grants must be made again after each build"
        }
        return "Unsigned"
    }

    // MARK: Asking and repairing

    /// Touches standard `SystemPolicyAllFiles`-protected paths so macOS automatically lists
    /// KramaIsland (toggled Off) in System Settings ▸ Privacy & Security ▸ Full Disk Access.
    /// Never grants access by itself — the user must still explicitly enable the switch.
    static func registerForFullDiskAccess() {
        guard isBundled, check(.fullDiskAccess) == .denied else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let protectedDirs = [
            home.appendingPathComponent("Library/Safari"),
            home.appendingPathComponent("Library/Mail"),
            home.appendingPathComponent("Library/Messages"),
            NotificationWatcher.databaseURL.deletingLastPathComponent(),
        ]
        for url in protectedDirs {
            _ = try? FileManager.default.contentsOfDirectory(atPath: url.path)
        }
        let protectedFiles = [
            home.appendingPathComponent("Library/Safari/Bookmarks.plist").path,
            home.appendingPathComponent("Library/Messages/chat.db").path,
        ]
        for path in protectedFiles {
            let fd = Darwin.open(path, O_RDONLY)
            if fd >= 0 { Darwin.close(fd) }
        }
    }

    static func ask(_ p: Permission, openPane: Bool = true) {
        switch p {
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            if openPane { PrivacyPane.open(p.pane) }
        case .fullDiskAccess:
            registerForFullDiskAccess()
            if openPane { PrivacyPane.open(p.pane) }
        case .bluetooth:
            if openPane { PrivacyPane.open(p.pane) }
        case .calendar:
            if let calendarRequest {
                calendarRequest()
            } else {
                let store = EKEventStore()
                let done: (Bool, Error?) -> Void = { _, _ in _ = store }
                if #available(macOS 14, *) { store.requestFullAccessToEvents(completion: done) }
                else { store.requestAccess(to: .event, completion: done) }
            }
        case .camera:
            AVCaptureDevice.requestAccess(for: .video) { _ in }
        }
    }

    /// Removes KramaIsland's entry for the service (or every service with `nil`) so macOS forgets
    /// a stale grant and asks fresh.
    static func reset(_ p: Permission?, completion: @escaping (Bool, String) -> Void) {
        let service = p?.tccService ?? "All"
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            proc.arguments = ["reset", service, bundleID]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            var ok = false
            var message = ""
            do {
                try proc.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                ok = proc.terminationStatus == 0
                message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            } catch {
                message = error.localizedDescription
            }
            NSLog("KramaIsland permissions: tccutil reset %@ %@ → %@ %@", service, bundleID, ok ? "ok" : "failed", message)
            DispatchQueue.main.async {
                if ok {
                    let d = UserDefaults.standard
                    for q in Permission.allCases where p == nil || p == q {
                        d.removeObject(forKey: grantedKey(q))
                        d.removeObject(forKey: staleKey(q))
                    }
                    NotificationCenter.default.post(name: .notchPermissionsReset, object: nil)
                }
                completion(ok, message)
            }
        }
    }

    /// Reset, then ask again.
    static func repair(_ p: Permission, completion: @escaping (Bool, String) -> Void = { _, _ in }) {
        reset(p) { ok, message in
            if ok { ask(p) }
            completion(ok, message)
        }
    }

    /// Runs once per build identity right after launch to clear stale core TCC entries.
    static func repairAfterLaunchIfNeeded() {
        guard isBundled else { return }
        let d = UserDefaults.standard
        let previous = d.string(forKey: identityKey)
        d.set(codeIdentity, forKey: identityKey)
        guard previous != codeIdentity else { return }
        NSLog("KramaIsland permissions: identity %@ → %@, checking grants", previous ?? "none", codeIdentity)

        let stale = Permission.coreCases.filter { check($0) == .denied }
        for p in stale {
            reset(p) { ok, _ in
                if ok, p == .accessibility { ask(.accessibility, openPane: false) }
            }
        }
    }
}
