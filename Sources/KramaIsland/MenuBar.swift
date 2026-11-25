import AppKit

final class MenuBarController: NSObject {
    var openShade: (() -> Void)?
    var openLauncher: (() -> Void)?
    var openSettings: (() -> Void)?

    private var item: NSStatusItem?

    func setVisible(_ visible: Bool) {
        if visible, item == nil {
            make()
        } else if !visible, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    private func make() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.makeTemplateIcon()
        item.button?.image?.accessibilityDescription = "KramaIsland"
        item.menu = buildMenu()
        self.item = item
    }

    /// Bespoke Retina template icon: a crisp MacBook display outline with KramaIsland's signature
    /// top-center Dynamic Island notch cutout. Adapts automatically to light and dark menu bars.
    private static func makeTemplateIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.labelColor.setStroke()
            NSColor.labelColor.setFill()

            // Rounded display silhouette
            let frame = NSRect(x: 1.75, y: 3.25, width: 14.5, height: 11.5)
            let outline = NSBezierPath(roundedRect: frame, xRadius: 3.2, yRadius: 3.2)
            outline.lineWidth = 1.4
            outline.stroke()

            // Top-center Dynamic Island notch pill anchored flush to top edge
            let notchW: CGFloat = 6.8
            let notchH: CGFloat = 3.1
            let notchX = frame.midX - notchW / 2
            let topY = frame.maxY - 0.1
            let botY = topY - notchH
            let r: CGFloat = 1.45

            let notch = NSBezierPath()
            notch.move(to: NSPoint(x: notchX, y: topY))
            notch.line(to: NSPoint(x: notchX + notchW, y: topY))
            notch.line(to: NSPoint(x: notchX + notchW, y: botY + r))
            notch.appendArc(withCenter: NSPoint(x: notchX + notchW - r, y: botY + r),
                            radius: r, startAngle: 0, endAngle: -90, clockwise: true)
            notch.line(to: NSPoint(x: notchX + r, y: botY))
            notch.appendArc(withCenter: NSPoint(x: notchX + r, y: botY + r),
                            radius: r, startAngle: -90, endAngle: -180, clockwise: true)
            notch.close()
            notch.fill()

            // Subtle floating card indicator inside the display
            let pill = NSBezierPath(roundedRect: NSRect(x: frame.midX - 3.6, y: frame.minY + 2.5, width: 7.2, height: 2.0),
                                    xRadius: 1.0, yRadius: 1.0)
            pill.fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: "Open Shade", action: #selector(shade), keyEquivalent: "").target = self
        let launcher = menu.addItem(withTitle: "Search Apps", action: #selector(launcherAction), keyEquivalent: "")
        launcher.target = self
        let layoutItem = menu.addItem(withTitle: "Window Layout", action: nil, keyEquivalent: "")
        layoutItem.submenu = buildWindowMenu()
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quiet Mode", action: #selector(toggleQuiet), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quiet for 1 Hour", action: #selector(quietHour), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Check for Updates…", action: #selector(updates), keyEquivalent: "").target = self
        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit KramaIsland", action: #selector(quit), keyEquivalent: "q").target = self
        menu.delegate = self
        return menu
    }

    @objc private func shade() { openShade?() }
    @objc private func launcherAction() { openLauncher?() }
    @objc private func settings() { openSettings?() }
    @objc private func toggleQuiet() { AppSettings.shared.setQuiet(!AppSettings.shared.quietManualOn) }
    @objc private func quietHour() { AppSettings.shared.setQuiet(true, for: 3600) }
    @objc private func updates() {
        if Updater.shared.newer == nil { Updater.shared.check(manual: true) }
        SettingsWindowController.shared.show(tab: "updates")
    }
    @objc private func toggleLogin(_ sender: NSMenuItem) {
        LaunchAtLogin.set(!LaunchAtLogin.isEnabled)
        sender.state = LaunchAtLogin.isEnabled ? .on : .off
    }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Window Layout Submenu

    private func buildWindowMenu() -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false
        let singles: [(String, WindowSnap, String)] = [
            ("Left Half   ⌃⌥←", .leftHalf, ""),
            ("Right Half   ⌃⌥→", .rightHalf, ""),
            ("Top Half   ⌃⌥↑", .topHalf, ""),
            ("Bottom Half   ⌃⌥↓", .bottomHalf, ""),
            ("Fill Screen   ⌃⌥↩", .maximize, ""),
            ("Center   ⌃⌥C", .center, ""),
        ]
        for (title, snap, _) in singles {
            let mi = sub.addItem(withTitle: title, action: #selector(runWindowSnap(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = snap.rawValue
        }
        let restore = sub.addItem(withTitle: "Restore Size   ⌃⌥⌫", action: #selector(runWindowRestore), keyEquivalent: "")
        restore.target = self
        sub.addItem(.separator())
        let tiles: [(String, MultiTilePreset)] = [
            ("Tile 2 Apps Side-by-Side   ⌃⌥2", .splitTwo),
            ("Tile 2 Apps (2/3 + 1/3)", .focusTwo),
            ("Tile 3 Apps in Columns   ⌃⌥3", .threeColumns),
            ("Tile 4 Apps in 2×2 Grid   ⌃⌥4", .gridFour),
        ]
        for (title, preset) in tiles {
            let mi = sub.addItem(withTitle: title, action: #selector(runMultiTile(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = preset.rawValue
        }
        let custom = sub.addItem(
            withTitle: "Tile Project Grid (\(AppSettings.shared.customGridLabel))   ⌃⌥G",
            action: #selector(runCustomGridTile),
            keyEquivalent: ""
        )
        custom.target = self
        return sub
    }

    @objc private func runWindowSnap(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let snap = WindowSnap(rawValue: raw) else { return }
        WindowManager.shared.snap(snap)
    }

    @objc private func runWindowRestore() {
        WindowManager.shared.restore()
    }

    @objc private func runMultiTile(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let preset = MultiTilePreset(rawValue: raw) else { return }
        WindowManager.shared.tile(preset)
    }

    @objc private func runCustomGridTile() {
        WindowManager.shared.tileCustomGrid()
    }
}

extension MenuBarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.action == #selector(toggleLogin) {
            item.state = LaunchAtLogin.isEnabled ? .on : .off
        }
        let s = AppSettings.shared
        for item in menu.items {
            if let sub = item.submenu {
                for subItem in sub.items where subItem.action == #selector(runCustomGridTile) {
                    subItem.title = "Tile Project Grid (\(s.customGridLabel))   ⌃⌥G"
                }
            }
        }
        for item in menu.items where item.action == #selector(toggleQuiet) {
            item.state = s.quietManualOn ? .on : .off
            item.title = s.quietManualOn && s.quietUntil > 0
                ? "Quiet Mode (until \(Date(timeIntervalSince1970: s.quietUntil).formatted(date: .omitted, time: .shortened)))"
                : "Quiet Mode"
        }
        for item in menu.items where item.action == #selector(launcherAction) {
            item.title = "Search Apps   \(AppSettings.shared.hotkeyDescription)"
        }
        for item in menu.items where item.action == #selector(updates) {
            item.title = Updater.shared.available.map { "Update to \($0.version)…" } ?? "Check for Updates…"
        }
    }
}
