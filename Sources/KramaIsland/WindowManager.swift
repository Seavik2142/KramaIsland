import AppKit
import ApplicationServices
import SwiftUI

/// Single-window snap zones, inspired by Windows 11 Snap Layouts.
enum WindowSnap: String, CaseIterable, Identifiable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case leftThird, centerThird, rightThird
    case leftTwoThirds, rightTwoThirds
    case maximize, center

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftHalf: return "Left Half"
        case .rightHalf: return "Right Half"
        case .topHalf: return "Top Half"
        case .bottomHalf: return "Bottom Half"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        case .leftThird: return "Left Third"
        case .centerThird: return "Center Third"
        case .rightThird: return "Right Third"
        case .leftTwoThirds: return "Left Two-Thirds"
        case .rightTwoThirds: return "Right Two-Thirds"
        case .maximize: return "Fill Screen"
        case .center: return "Center"
        }
    }

    var symbol: String {
        switch self {
        case .leftHalf: return "rectangle.lefthalf.filled"
        case .rightHalf: return "rectangle.righthalf.filled"
        case .topHalf: return "rectangle.tophalf.filled"
        case .bottomHalf: return "rectangle.bottomhalf.filled"
        case .topLeft: return "rectangle.inset.topleft.filled"
        case .topRight: return "rectangle.inset.topright.filled"
        case .bottomLeft: return "rectangle.inset.bottomleft.filled"
        case .bottomRight: return "rectangle.inset.bottomright.filled"
        case .leftThird: return "rectangle.leadingthird.inset.filled"
        case .centerThird: return "rectangle.center.inset.filled"
        case .rightThird: return "rectangle.trailingthird.inset.filled"
        case .leftTwoThirds: return "sidebar.left"
        case .rightTwoThirds: return "sidebar.right"
        case .maximize: return "arrow.up.left.and.arrow.down.right"
        case .center: return "rectangle.center.inset.filled"
        }
    }

    /// Normalized rectangle inside the display's visible area (origin top-left, 0...1).
    var normalizedRect: CGRect {
        switch self {
        case .leftHalf:       return CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .rightHalf:      return CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .topHalf:        return CGRect(x: 0, y: 0, width: 1, height: 0.5)
        case .bottomHalf:     return CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        case .topLeft:        return CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        case .topRight:       return CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        case .bottomLeft:     return CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        case .bottomRight:    return CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        case .leftThird:      return CGRect(x: 0, y: 0, width: 1.0 / 3.0, height: 1)
        case .centerThird:    return CGRect(x: 1.0 / 3.0, y: 0, width: 1.0 / 3.0, height: 1)
        case .rightThird:     return CGRect(x: 2.0 / 3.0, y: 0, width: 1.0 / 3.0, height: 1)
        case .leftTwoThirds:  return CGRect(x: 0, y: 0, width: 2.0 / 3.0, height: 1)
        case .rightTwoThirds: return CGRect(x: 1.0 / 3.0, y: 0, width: 2.0 / 3.0, height: 1)
        case .maximize:       return CGRect(x: 0, y: 0, width: 1, height: 1)
        case .center:         return CGRect(x: 0.11, y: 0.08, width: 0.78, height: 0.84)
        }
    }

    /// Computes pixel-accurate AX (top-left global) frame for `visibleFrame` with optional gap.
    func axFrame(in screen: NSScreen, gap: CGFloat) -> CGRect {
        let vf = screen.visibleFrame
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let axTop = primaryHeight - vf.maxY
        let usable = CGRect(
            x: vf.minX + gap,
            y: axTop + gap,
            width: max(100, vf.width - gap * 2),
            height: max(100, vf.height - gap * 2)
        )
        let n = normalizedRect
        let rawX = usable.minX + usable.width * n.minX
        let rawY = usable.minY + usable.height * n.minY
        let rawW = usable.width * n.width
        let rawH = usable.height * n.height

        let halfGap = gap / 2
        let insetLeft = n.minX > 0.001 ? halfGap : 0
        let insetRight = n.maxX < 0.999 ? halfGap : 0
        let insetTop = n.minY > 0.001 ? halfGap : 0
        let insetBottom = n.maxY < 0.999 ? halfGap : 0

        return CGRect(
            x: (rawX + insetLeft).rounded(),
            y: (rawY + insetTop).rounded(),
            width: max(120, (rawW - insetLeft - insetRight).rounded()),
            height: max(100, (rawH - insetTop - insetBottom).rounded())
        )
    }
}

/// One cell inside an arbitrary `rows × cols` workspace grid (0-indexed from top-left).
struct WindowGridCell: Hashable, Identifiable {
    let row: Int
    let col: Int
    let rows: Int
    let cols: Int

    var id: String { "\(rows)x\(cols)-\(row)-\(col)" }
    var label: String { "R\(row + 1)·C\(col + 1)" }
    var title: String { "Row \(row + 1), Col \(col + 1) (\(rows)×\(cols))" }

    var normalizedRect: CGRect {
        let w = 1.0 / CGFloat(max(1, cols))
        let h = 1.0 / CGFloat(max(1, rows))
        return CGRect(x: CGFloat(col) * w, y: CGFloat(row) * h, width: w, height: h)
    }

    func axFrame(in screen: NSScreen, gap: CGFloat) -> CGRect {
        let vf = screen.visibleFrame
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let axTop = primaryHeight - vf.maxY
        let usable = CGRect(
            x: vf.minX + gap,
            y: axTop + gap,
            width: max(100, vf.width - gap * 2),
            height: max(100, vf.height - gap * 2)
        )
        let n = normalizedRect
        let rawX = usable.minX + usable.width * n.minX
        let rawY = usable.minY + usable.height * n.minY
        let rawW = usable.width * n.width
        let rawH = usable.height * n.height

        let halfGap = gap / 2
        let insetLeft = n.minX > 0.001 ? halfGap : 0
        let insetRight = n.maxX < 0.999 ? halfGap : 0
        let insetTop = n.minY > 0.001 ? halfGap : 0
        let insetBottom = n.maxY < 0.999 ? halfGap : 0

        return CGRect(
            x: (rawX + insetLeft).rounded(),
            y: (rawY + insetTop).rounded(),
            width: max(120, (rawW - insetLeft - insetRight).rounded()),
            height: max(100, (rawH - insetTop - insetBottom).rounded())
        )
    }
}

/// Multi-app workspace layouts: arrange 2, 3, or 4 platforms cleanly on one display with one click.
enum MultiTilePreset: String, CaseIterable, Identifiable {
    case splitTwo      // 50% | 50%
    case focusTwo      // 66% | 33%
    case threeColumns  // 33% | 33% | 33%
    case gridFour      // 2x2 quadrants

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .splitTwo: return "2 Split"
        case .focusTwo: return "2 Focus"
        case .threeColumns: return "3 Cols"
        case .gridFour: return "4 Grid"
        }
    }

    var title: String {
        switch self {
        case .splitTwo: return "Tile 2 Apps Side-by-Side"
        case .focusTwo: return "Tile 2 Apps (2/3 + 1/3)"
        case .threeColumns: return "Tile 3 Apps in Columns"
        case .gridFour: return "Tile 4 Apps in 2×2 Grid"
        }
    }

    var symbol: String {
        switch self {
        case .splitTwo: return "rectangle.split.2x1.fill"
        case .focusTwo: return "sidebar.right"
        case .threeColumns: return "rectangle.split.3x1.fill"
        case .gridFour: return "rectangle.split.2x2.fill"
        }
    }

    var slots: [WindowSnap] {
        switch self {
        case .splitTwo: return [.leftHalf, .rightHalf]
        case .focusTwo: return [.leftTwoThirds, .rightThird]
        case .threeColumns: return [.leftThird, .centerThird, .rightThird]
        case .gridFour: return [.topLeft, .topRight, .bottomLeft, .bottomRight]
        }
    }
}

/// Manages Windows 11-style window snapping and multi-app workspace tiling using macOS Accessibility.
final class WindowManager: ObservableObject {
    static let shared = WindowManager()

    /// Most recently active external apps (newest first), excluding KramaIsland itself.
    @Published private(set) var recentApps: [NSRunningApplication] = []

    var targetApp: NSRunningApplication? {
        recentApps.first { !$0.isTerminated } ?? frontmostExternalApp()
    }

    private var activationObserver: Any?
    private var previousFrames: [pid_t: CGRect] = [:]

    private init() {
        seedRecentApps()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.recordActivation(app)
        }
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    private func recordActivation(_ app: NSRunningApplication) {
        guard app != NSRunningApplication.current,
              app.activationPolicy == .regular,
              !app.isTerminated else { return }
        recentApps.removeAll { $0.processIdentifier == app.processIdentifier || $0.isTerminated }
        recentApps.insert(app, at: 0)
        if recentApps.count > 10 { recentApps.removeLast(recentApps.count - 10) }
    }

    private func seedRecentApps() {
        var ordered: [NSRunningApplication] = []
        var seen = Set<pid_t>()

        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]] {
            for info in list {
                guard (info[kCGWindowLayer as String] as? Int) == 0,
                      let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                      !seen.contains(pid),
                      let app = NSRunningApplication(processIdentifier: pid),
                      app != NSRunningApplication.current,
                      app.activationPolicy == .regular else { continue }
                seen.insert(pid)
                ordered.append(app)
                if ordered.count >= 8 { break }
            }
        }
        if let front = frontmostExternalApp(), !seen.contains(front.processIdentifier) {
            ordered.insert(front, at: 0)
        }
        recentApps = ordered
    }

    private func frontmostExternalApp() -> NSRunningApplication? {
        if let front = NSWorkspace.shared.frontmostApplication,
           front != NSRunningApplication.current,
           front.activationPolicy == .regular {
            return front
        }
        return NSWorkspace.shared.runningApplications.first {
            $0 != NSRunningApplication.current && $0.activationPolicy == .regular && !$0.isHidden
        }
    }

    // MARK: - Snap & Tile Actions

    @discardableResult
    func snap(_ zone: WindowSnap, app explicitApp: NSRunningApplication? = nil) -> Bool {
        guard ensureAccessibility() else { return false }
        guard let app = explicitApp ?? targetApp,
              let window = focusedWindow(for: app.processIdentifier) else {
            return false
        }
        if let current = windowFrame(window) {
            previousFrames[app.processIdentifier] = current
        }
        let screen = screenFor(window: window)
        let gap = CGFloat(AppSettings.shared.windowSnapGap)
        let target = zone.axFrame(in: screen, gap: gap)
        let ok = apply(frame: target, to: window, pid: app.processIdentifier)
        if ok {
            app.activate(options: [])
            Feedback.tap()
            announce(symbol: zone.symbol, title: zone.title, subtitle: app.localizedName ?? "Window")
        }
        return ok
    }

    @discardableResult
    func restore(app explicitApp: NSRunningApplication? = nil) -> Bool {
        guard ensureAccessibility() else { return false }
        guard let app = explicitApp ?? targetApp,
              let saved = previousFrames[app.processIdentifier],
              let window = focusedWindow(for: app.processIdentifier) else {
            return false
        }
        let ok = apply(frame: saved, to: window, pid: app.processIdentifier)
        if ok {
            previousFrames.removeValue(forKey: app.processIdentifier)
            app.activate(options: [])
            Feedback.tap()
            announce(symbol: "arrow.uturn.backward", title: "Restored Window", subtitle: app.localizedName ?? "Window")
        }
        return ok
    }

    /// Tiles the top N most recently active apps into `preset`'s zones on the active display.
    @discardableResult
    func tile(_ preset: MultiTilePreset) -> Bool {
        guard ensureAccessibility() else { return false }
        let candidates = tileCandidates(limit: preset.slots.count)
        guard !candidates.isEmpty else { return false }

        let primaryScreen = candidates.first.flatMap { focusedWindow(for: $0.processIdentifier) }.map { screenFor(window: $0) }
            ?? NotchGeometry.current.screen
        let gap = CGFloat(AppSettings.shared.windowSnapGap)

        var tiledNames: [String] = []
        for (idx, app) in candidates.enumerated() {
            guard idx < preset.slots.count,
                  let window = focusedWindow(for: app.processIdentifier) else { continue }
            if let current = windowFrame(window) {
                previousFrames[app.processIdentifier] = current
            }
            if app.isHidden { app.unhide() }
            let target = preset.slots[idx].axFrame(in: primaryScreen, gap: gap)
            if apply(frame: target, to: window, pid: app.processIdentifier) {
                // Raise each tiled window in reverse order afterwards so all stay visible together.
                tiledNames.append(app.localizedName ?? "App")
            }
        }

        // Bring all tiled windows forward (back-to-front so the newest stays focused).
        for app in candidates.reversed() {
            app.activate(options: [])
        }
        guard !tiledNames.isEmpty else { return false }
        Feedback.tap()
        announce(symbol: preset.symbol, title: preset.title, subtitle: tiledNames.joined(separator: " · "))
        return true
    }

    /// Snaps the active project window into a specific `(row, col)` cell of an arbitrary `rows × cols` grid.
    @discardableResult
    func snapToGrid(row: Int, col: Int, rows: Int? = nil, cols: Int? = nil, app explicitApp: NSRunningApplication? = nil) -> Bool {
        guard ensureAccessibility() else { return false }
        let s = AppSettings.shared
        let totalRows = min(max(rows ?? s.clampedGridRows, 1), 4)
        let totalCols = min(max(cols ?? s.clampedGridColumns, 1), 4)
        let cell = WindowGridCell(
            row: min(max(row, 0), totalRows - 1),
            col: min(max(col, 0), totalCols - 1),
            rows: totalRows,
            cols: totalCols
        )
        guard let app = explicitApp ?? targetApp,
              let window = focusedWindow(for: app.processIdentifier) else {
            return false
        }
        if let current = windowFrame(window) {
            previousFrames[app.processIdentifier] = current
        }
        let screen = screenFor(window: window)
        let gap = CGFloat(s.windowSnapGap)
        let target = cell.axFrame(in: screen, gap: gap)
        let ok = apply(frame: target, to: window, pid: app.processIdentifier)
        if ok {
            app.activate(options: [])
            Feedback.tap()
            announce(symbol: "square.grid.3x2.fill", title: cell.title, subtitle: app.localizedName ?? "Window")
        }
        return ok
    }

    /// Tiles open project windows (across apps and multi-window apps) into the configured `rows × cols` grid.
    @discardableResult
    func tileCustomGrid(rows: Int? = nil, cols: Int? = nil) -> Bool {
        guard ensureAccessibility() else { return false }
        let s = AppSettings.shared
        let totalRows = min(max(rows ?? s.clampedGridRows, 1), 4)
        let totalCols = min(max(cols ?? s.clampedGridColumns, 1), 4)
        let slotCount = totalRows * totalCols

        let candidates = tileWindowCandidates(limit: slotCount)
        guard !candidates.isEmpty else { return false }

        let primaryScreen = candidates.first.map { screenFor(window: $0.window) } ?? NotchGeometry.current.screen
        let gap = CGFloat(s.windowSnapGap)

        var cells: [WindowGridCell] = []
        for r in 0..<totalRows {
            for c in 0..<totalCols {
                cells.append(WindowGridCell(row: r, col: c, rows: totalRows, cols: totalCols))
            }
        }

        var tiledNames: [String] = []
        var activatedApps: [NSRunningApplication] = []
        var seenPIDs = Set<pid_t>()

        for (idx, item) in candidates.enumerated() {
            guard idx < cells.count else { continue }
            if previousFrames[item.app.processIdentifier] == nil, let current = windowFrame(item.window) {
                previousFrames[item.app.processIdentifier] = current
            }
            if item.app.isHidden { item.app.unhide() }
            let target = cells[idx].axFrame(in: primaryScreen, gap: gap)
            if apply(frame: target, to: item.window, pid: item.app.processIdentifier) {
                _ = AXUIElementPerformAction(item.window, kAXRaiseAction as CFString)
                let name = item.app.localizedName ?? "App"
                if !tiledNames.contains(name) { tiledNames.append(name) }
                if seenPIDs.insert(item.app.processIdentifier).inserted {
                    activatedApps.append(item.app)
                }
            }
        }

        for app in activatedApps.reversed() {
            app.activate(options: [])
        }
        guard !tiledNames.isEmpty else { return false }
        Feedback.tap()
        announce(
            symbol: "square.grid.3x2.fill",
            title: "Tiled \(candidates.count) Window\(candidates.count == 1 ? "" : "s") (\(totalRows)×\(totalCols))",
            subtitle: tiledNames.joined(separator: " · ")
        )
        return true
    }

    private struct TileWindowCandidate {
        let app: NSRunningApplication
        let window: AXUIElement
    }

    /// Collects up to `limit` visible standard windows: takes the primary window of each distinct
    /// recent app first, then fills any remaining slots with additional open windows (e.g. a second
    /// browser or IDE window for the same project).
    private func tileWindowCandidates(limit: Int) -> [TileWindowCandidate] {
        var orderedApps: [NSRunningApplication] = []
        var seenPIDs = Set<pid_t>()

        for app in recentApps where !app.isTerminated && !app.isHidden {
            if seenPIDs.insert(app.processIdentifier).inserted { orderedApps.append(app) }
        }
        for app in NSWorkspace.shared.runningApplications
        where app != NSRunningApplication.current && app.activationPolicy == .regular && !app.isHidden {
            if seenPIDs.insert(app.processIdentifier).inserted { orderedApps.append(app) }
        }

        var perAppWindows: [(app: NSRunningApplication, windows: [AXUIElement])] = []
        for app in orderedApps {
            let wins = standardWindows(for: app.processIdentifier)
            if !wins.isEmpty { perAppWindows.append((app, wins)) }
        }

        var result: [TileWindowCandidate] = []
        var round = 0
        while result.count < limit {
            var addedThisRound = false
            for entry in perAppWindows {
                if round < entry.windows.count {
                    result.append(TileWindowCandidate(app: entry.app, window: entry.windows[round]))
                    addedThisRound = true
                    if result.count >= limit { break }
                }
            }
            if !addedThisRound { break }
            round += 1
        }
        return result
    }

    private func standardWindows(for pid: pid_t) -> [AXUIElement] {
        let appEl = AXUIElementCreateApplication(pid)
        var listRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &listRef) == .success,
              let windows = listRef as? [AXUIElement] else {
            return focusedWindow(for: pid).map { [$0] } ?? []
        }
        var valid: [AXUIElement] = []
        for win in windows {
            var subrole: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, kAXSubroleAttribute as CFString, &subrole) == .success,
               let s = subrole as? String, s != (kAXStandardWindowSubrole as String) {
                continue
            }
            var minimized: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minimized) == .success,
               (minimized as? Bool) == true {
                continue
            }
            valid.append(win)
        }
        if valid.isEmpty, let focused = focusedWindow(for: pid) { return [focused] }
        return valid
    }

    func tileCandidates(limit: Int) -> [NSRunningApplication] {
        var result: [NSRunningApplication] = []
        var seen = Set<pid_t>()

        for app in recentApps where !app.isTerminated && !app.isHidden {
            guard !seen.contains(app.processIdentifier),
                  focusedWindow(for: app.processIdentifier) != nil else { continue }
            seen.insert(app.processIdentifier)
            result.append(app)
            if result.count >= limit { return result }
        }
        // Fallback to any other visible regular apps with open windows.
        for app in NSWorkspace.shared.runningApplications
        where app != NSRunningApplication.current && app.activationPolicy == .regular && !app.isHidden {
            guard !seen.contains(app.processIdentifier),
                  focusedWindow(for: app.processIdentifier) != nil else { continue }
            seen.insert(app.processIdentifier)
            result.append(app)
            if result.count >= limit { break }
        }
        return result
    }

    // MARK: - Global ⌃⌥ Shortcuts

    /// Handles Control + Option window snap shortcuts directly from HotkeyManager's CGEvent tap.
    func handleShortcut(keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard AppSettings.shared.windowSnapEnabled, AppSettings.shared.windowSnapShortcuts else { return false }
        let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        let clean = flags.intersection(relevant)
        guard clean == [.maskControl, .maskAlternate] else { return false }

        switch keyCode {
        case 123: DispatchQueue.main.async { self.snap(.leftHalf) }; return true      // ⌃⌥ ←
        case 124: DispatchQueue.main.async { self.snap(.rightHalf) }; return true     // ⌃⌥ →
        case 126: DispatchQueue.main.async { self.snap(.topHalf) }; return true       // ⌃⌥ ↑
        case 125: DispatchQueue.main.async { self.snap(.bottomHalf) }; return true    // ⌃⌥ ↓
        case 36:  DispatchQueue.main.async { self.snap(.maximize) }; return true      // ⌃⌥ ↩
        case 8:   DispatchQueue.main.async { self.snap(.center) }; return true        // ⌃⌥ C
        case 51:  DispatchQueue.main.async { self.restore() }; return true            // ⌃⌥ ⌫
        case 19:  DispatchQueue.main.async { self.tile(.splitTwo) }; return true      // ⌃⌥ 2
        case 20:  DispatchQueue.main.async { self.tile(.threeColumns) }; return true  // ⌃⌥ 3
        case 21:  DispatchQueue.main.async { self.tile(.gridFour) }; return true      // ⌃⌥ 4
        case 5:   DispatchQueue.main.async { self.tileCustomGrid() }; return true     // ⌃⌥ G
        default: return false
        }
    }

    // MARK: - Accessibility Plumbing

    private func ensureAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        Permissions.ask(.accessibility, openPane: true)
        return false
    }

    private func focusedWindow(for pid: pid_t) -> AXUIElement? {
        let appEl = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
           let winRef, CFGetTypeID(winRef) == AXUIElementGetTypeID() {
            return (winRef as! AXUIElement)
        }
        var listRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &listRef) == .success,
           let windows = listRef as? [AXUIElement] {
            return windows.first { win in
                var subrole: CFTypeRef?
                if AXUIElementCopyAttributeValue(win, kAXSubroleAttribute as CFString, &subrole) == .success,
                   let s = subrole as? String {
                    return s == (kAXStandardWindowSubrole as String)
                }
                return true
            } ?? windows.first
        }
        return nil
    }

    private func windowFrame(_ window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &pt),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }

    private func apply(frame: CGRect, to window: AXUIElement, pid: pid_t) -> Bool {
        let appEl = AXUIElementCreateApplication(pid)
        // Electron/Chromium apps can animate sluggishly when AXEnhancedUserInterface is active.
        var enhancedRef: CFTypeRef?
        let hadEnhanced = AXUIElementCopyAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, &enhancedRef) == .success
            && (enhancedRef as? Bool) == true
        if hadEnhanced {
            AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        }
        defer {
            if hadEnhanced {
                AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            }
        }

        // Un-fullscreen if needed isn't forced; set size -> position -> size for cross-display exactness.
        var pos = frame.origin
        var size = frame.size
        guard let posVal = AXValueCreate(.cgPoint, &pos),
              let sizeVal = AXValueCreate(.cgSize, &size) else { return false }

        _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeVal)
        let rPos = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posVal)
        let rSize = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeVal)
        return rPos == .success || rSize == .success
    }

    private func screenFor(window: AXUIElement) -> NSScreen {
        guard let axRect = windowFrame(window) else { return NotchGeometry.current.screen }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let appKitCenter = CGPoint(x: axRect.midX, y: primaryHeight - axRect.midY)
        return NSScreen.screens.first { $0.frame.contains(appKitCenter) } ?? NotchGeometry.current.screen
    }

    private func announce(symbol: String, title: String, subtitle: String) {
        ActivityCenter.shared.show(LiveActivity(
            id: "window.snap",
            kind: .custom,
            symbol: symbol,
            title: title,
            subtitle: subtitle,
            progress: nil,
            tint: UI.info,
            duration: 2.2
        ))
    }
}

// MARK: - Windows 11-Style Snap Layouts Shade Card

/// Visual Windows 11-inspired Snap Layouts card for the Shade: click any region in the
/// mini-display diagrams (including your custom Rows × Columns project grid) to snap the active
/// app, or click a multi-app Tile preset to arrange all project windows on one screen at once.
struct WindowSnapCard: View {
    @ObservedObject var manager: WindowManager
    @ObservedObject private var settings = AppSettings.shared
    @State private var showGridBuilder = false
    var onApplied: () -> Void = {}

    private var targetName: String {
        manager.targetApp?.localizedName ?? "Active Window"
    }

    private var rows: Int { settings.clampedGridRows }
    private var cols: Int { settings.clampedGridColumns }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header with active target app + live R×C grid toggle + Restore / Center / Fill
            HStack(spacing: 7) {
                if let icon = manager.targetApp?.icon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 16, height: 16)
                } else {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(UI.secondaryText)
                        .frame(width: 16, height: 16)
                }
                Text("WINDOW LAYOUT · \(targetName.uppercased())")
                    .font(UI.eyebrow)
                    .tracking(0.6)
                    .foregroundStyle(UI.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 4)

                Button {
                    withAnimation(Motion.quick) { showGridBuilder.toggle() }
                } label: {
                    HStack(spacing: 3.5) {
                        Image(systemName: "square.grid.3x2.fill")
                            .font(.system(size: 8.5, weight: .bold))
                        Text("\(rows)×\(cols)")
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Image(systemName: showGridBuilder ? "chevron.up" : "chevron.down")
                            .font(.system(size: 7.5, weight: .bold))
                    }
                    .foregroundStyle(showGridBuilder ? .white : UI.info)
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(showGridBuilder ? UI.info.opacity(0.38) : UI.info.opacity(0.16), in: Capsule())
                    .overlay(Capsule().strokeBorder(UI.info.opacity(showGridBuilder ? 0.65 : 0.30), lineWidth: 0.75))
                }
                .buttonStyle(.plain)
                .help("Customize project grid Rows × Columns")

                IconButton(symbol: "arrow.uturn.backward", size: 22, help: "Restore previous window size (⌃⌥⌫)") {
                    if manager.restore() { onApplied() }
                }
                IconButton(symbol: "rectangle.center.inset.filled", size: 22, help: "Center window (⌃⌥C)") {
                    if manager.snap(.center) { onApplied() }
                }
                IconButton(symbol: "arrow.up.left.and.arrow.down.right", size: 22, help: "Fill screen (⌃⌥↩)") {
                    if manager.snap(.maximize) { onApplied() }
                }
            }

            if showGridBuilder {
                customGridPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                // Visual Windows 11 Snap Layout thumbnails (click any zone to snap)
                HStack(spacing: 8) {
                    // 1. 50 / 50 Split
                    SnapDiagram {
                        HStack(spacing: 3) {
                            SnapZoneBox(snap: .leftHalf) { trigger($0) }
                            SnapZoneBox(snap: .rightHalf) { trigger($0) }
                        }
                    }
                    // 2. 2/3 + 1/3 Focus Split
                    SnapDiagram {
                        GeometryReader { geo in
                            let gap: CGFloat = 3
                            let w = max(0, geo.size.width - gap)
                            HStack(spacing: gap) {
                                SnapZoneBox(snap: .leftTwoThirds) { trigger($0) }
                                    .frame(width: w * 0.65)
                                SnapZoneBox(snap: .rightThird) { trigger($0) }
                                    .frame(width: w * 0.35)
                            }
                        }
                    }
                    // 3. 3 Equal Columns
                    SnapDiagram {
                        HStack(spacing: 3) {
                            SnapZoneBox(snap: .leftThird) { trigger($0) }
                            SnapZoneBox(snap: .centerThird) { trigger($0) }
                            SnapZoneBox(snap: .rightThird) { trigger($0) }
                        }
                    }
                    // 4. Live Custom Rows × Columns Grid (mirrors Settings)
                    SnapDiagram {
                        VStack(spacing: rows >= 3 ? 2 : 3) {
                            ForEach(0..<rows, id: \.self) { r in
                                HStack(spacing: cols >= 3 ? 2 : 3) {
                                    ForEach(0..<cols, id: \.self) { c in
                                        GridCellBox(
                                            cell: WindowGridCell(row: r, col: c, rows: rows, cols: cols),
                                            compact: true
                                        ) { cell in
                                            triggerGrid(cell)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(height: 44)
            }

            // One-click Multi-App Workspace Tiling row
            HStack(spacing: 6) {
                MultiTilePill(symbol: MultiTilePreset.splitTwo.symbol, label: "2 Split", help: MultiTilePreset.splitTwo.title) {
                    if manager.tile(.splitTwo) { onApplied() }
                }
                MultiTilePill(symbol: MultiTilePreset.focusTwo.symbol, label: "2 Focus", help: MultiTilePreset.focusTwo.title) {
                    if manager.tile(.focusTwo) { onApplied() }
                }
                MultiTilePill(symbol: MultiTilePreset.threeColumns.symbol, label: "3 Cols", help: MultiTilePreset.threeColumns.title) {
                    if manager.tile(.threeColumns) { onApplied() }
                }
                MultiTilePill(
                    symbol: "square.grid.3x2.fill",
                    label: "\(rows)×\(cols) Grid",
                    highlighted: true,
                    help: "Tile up to \(rows * cols) project windows into \(rows) rows × \(cols) columns (⌃⌥G)"
                ) {
                    if manager.tileCustomGrid() { onApplied() }
                }
            }
        }
        .foregroundStyle(.white)
        .islandCard(padding: 12)
    }

    /// Expanded interactive project-grid controls inside the Shade: live Row/Column steppers
    /// synced with Settings plus a full-width clickable R×C cell map.
    private var customGridPanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                gridStepper(title: "Rows", value: Binding(
                    get: { settings.clampedGridRows },
                    set: { settings.windowGridRows = min(max($0, 1), 4) }
                ))
                gridStepper(title: "Cols", value: Binding(
                    get: { settings.clampedGridColumns },
                    set: { settings.windowGridColumns = min(max($0, 1), 4) }
                ))
                Spacer(minLength: 2)
                Button {
                    SettingsWindowController.shared.show(tab: "general")
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(UI.secondaryText)
                        .frame(width: 24, height: 24)
                        .background(UI.controlFill, in: Circle())
                }
                .buttonStyle(.plain)
                .help("More Window Layout options in Settings")
            }

            // Full-width clickable Rows × Columns project screen preview
            VStack(spacing: 4) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: 4) {
                        ForEach(0..<cols, id: \.self) { c in
                            GridCellBox(
                                cell: WindowGridCell(row: r, col: c, rows: rows, cols: cols),
                                compact: false
                            ) { cell in
                                triggerGrid(cell)
                            }
                        }
                    }
                }
            }
            .padding(6)
            .frame(height: max(58, CGFloat(rows) * 26 + 12))
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.75))
        }
    }

    private func gridStepper(title: String, value: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(UI.secondaryText)
            HStack(spacing: 2) {
                Button {
                    if value.wrappedValue > 1 { value.wrappedValue -= 1; Feedback.tap() }
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(Color.white.opacity(value.wrappedValue > 1 ? 0.12 : 0.04), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(value.wrappedValue <= 1)

                Text("\(value.wrappedValue)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 16)

                Button {
                    if value.wrappedValue < 4 { value.wrappedValue += 1; Feedback.tap() }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(Color.white.opacity(value.wrappedValue < 4 ? 0.12 : 0.04), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(value.wrappedValue >= 4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(Color.white.opacity(0.06), in: Capsule())
    }

    private func trigger(_ zone: WindowSnap) {
        if manager.snap(zone) { onApplied() }
    }

    private func triggerGrid(_ cell: WindowGridCell) {
        if manager.snapToGrid(row: cell.row, col: cell.col, rows: cell.rows, cols: cell.cols) {
            onApplied()
        }
    }
}

private struct SnapDiagram<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.75))
    }
}

private struct SnapZoneBox: View {
    let snap: WindowSnap
    let action: (WindowSnap) -> Void
    @State private var hovering = false

    var body: some View {
        Button { action(snap) } label: {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(hovering ? UI.info : Color.white.opacity(0.18))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(hovering ? Color.white.opacity(0.45) : Color.clear, lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .help(snap.title)
    }
}

private struct GridCellBox: View {
    let cell: WindowGridCell
    let compact: Bool
    let action: (WindowGridCell) -> Void
    @State private var hovering = false

    var body: some View {
        Button { action(cell) } label: {
            ZStack {
                RoundedRectangle(cornerRadius: compact ? 3 : 6, style: .continuous)
                    .fill(hovering ? UI.info : Color.white.opacity(compact ? 0.18 : 0.14))
                    .overlay(RoundedRectangle(cornerRadius: compact ? 3 : 6, style: .continuous)
                        .strokeBorder(hovering ? Color.white.opacity(0.50) : Color.white.opacity(0.06), lineWidth: 0.75))
                if !compact {
                    Text(cell.label)
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(hovering ? .white : .white.opacity(0.65))
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .help("Snap active window to \(cell.title)")
    }
}

private struct MultiTilePill: View {
    let symbol: String
    let label: String
    var highlighted: Bool = false
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(hovering || highlighted ? .white : UI.info)
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(hovering || highlighted ? 1 : 0.88))
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background(
                hovering
                    ? UI.info.opacity(0.36)
                    : (highlighted ? UI.info.opacity(0.20) : UI.controlFill),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    hovering
                        ? UI.info.opacity(0.65)
                        : (highlighted ? UI.info.opacity(0.35) : Color.white.opacity(0.06)),
                    lineWidth: 0.75
                ))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .help(help)
    }
}
