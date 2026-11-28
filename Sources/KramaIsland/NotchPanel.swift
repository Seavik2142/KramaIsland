import AppKit
import Combine
import SwiftUI

/// Transparent, always-on-top, non-activating panel pinned to the top-centre of ONE specific display.
///
/// Each panel keeps a fixed frame large enough for every island state on its display and toggles
/// `ignoresMouseEvents` from live pointer hit-testing. Never resizing the NSWindow on hover
/// avoids backing-store reallocation freezes, coordinate-origin jumps, and AppKit tracking-area
/// flicker, while passing every click outside the island straight through to apps below.
final class NotchPanel: NSPanel {
    let displayID: CGDirectDisplayID
    private let state: IslandState
    private(set) var geometry: NotchGeometry
    private(set) var hiddenByPolicy = false

    private static let fixedWidth: CGFloat = IslandLayout.launcherWidth + 68
    private static let fixedHeight: CGFloat = 820

    init(state: IslandState, geometry: NotchGeometry) {
        self.state = state
        self.displayID = geometry.displayID
        self.geometry = geometry
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)

        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        appearance = NSAppearance(named: .darkAqua)
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        ignoresMouseEvents = true

        let hosting = NSHostingView(rootView: NotchView(state: state, displayID: geometry.displayID))
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        contentView = hosting
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show() {
        reposition(to: geometry)
        guard !hiddenByPolicy else { return }
        orderFrontRegardless()
    }

    /// Hidden over full-screen videos / full-screen apps / listed apps on THIS display only.
    func setHiddenByPolicy(_ hidden: Bool) {
        guard hidden != hiddenByPolicy else { return }
        hiddenByPolicy = hidden
        if hidden {
            ignoresMouseEvents = true
            if state.activeDisplayID == displayID {
                state.setHovering(false, on: displayID)
                if state.isShadeOpen { state.closeShade() }
                if state.isLauncherOpen { state.closeLauncher() }
            }
            orderOut(nil)
        } else {
            reposition(to: geometry)
            orderFrontRegardless()
        }
    }

    /// Called at launch, on display geometry changes, or when island size changes in Settings.
    /// Never called on hover.
    func reposition(to geo: NotchGeometry) {
        geometry = geo
        let sf = geo.screen.frame
        let s = AppSettings.shared
        let maxBodyW = max(IslandLayout.launcherWidth, s.clampedIslandWidth + 110)
        let width = min(sf.width, max(Self.fixedWidth, maxBodyW + 84))
        let height = min(sf.height, max(Self.fixedHeight, s.clampedIslandHeight + 230))
        let target = NSRect(x: (sf.midX - width / 2).rounded(),
                            y: sf.maxY - height,
                            width: width,
                            height: height)
        if frame != target {
            setFrame(target, display: false)
        }
        guard !hiddenByPolicy else { return }
        let layout = state.layout(for: displayID)
        if layout.isOpen && !state.isSizePreviewActive {
            makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            orderFrontRegardless()
        }
    }

    func applyLayoutOrder() {
        guard !hiddenByPolicy else { return }
        let layout = state.layout(for: displayID)
        if layout.isOpen && !state.isSizePreviewActive {
            makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            orderFrontRegardless()
        }
    }

    func isPointInsideIsland(_ pt: NSPoint, extraMargin: CGFloat = 0) -> Bool {
        guard !hiddenByPolicy else { return false }
        let sf = geometry.screen.frame
        let layout = state.layout(for: displayID)
        let rendered = state.renderedSurfaceSize(for: displayID)

        let width: CGFloat
        let height: CGFloat
        let horizontalPad: CGFloat
        let bottomPad: CGFloat

        switch layout.mode {
        case .collapsed, .compact:
            width = max(layout.surfaceWidth(geometry), rendered.width)
            height = max(layout.compactHeight(geometry), rendered.height)
            horizontalPad = 6 + extraMargin
            bottomPad = 4 + extraMargin
        default:
            width = max(layout.surfaceWidth(geometry), rendered.width)
            height = max(geometry.notchHeight + 36, rendered.height)
            horizontalPad = 10 + extraMargin
            bottomPad = 10 + extraMargin
        }

        let rect = NSRect(
            x: sf.midX - width / 2 - horizontalPad,
            y: sf.maxY - height - bottomPad,
            width: width + horizontalPad * 2,
            height: height + bottomPad + 4
        )
        return rect.contains(pt)
    }

    override func resignKey() {
        super.resignKey()
        guard !state.isSizePreviewActive else { return }
        // Only close if no sibling KramaIsland panel just became key.
        if NSApp.keyWindow is NotchPanel { return }
        if ProcessInfo.processInfo.environment["KRAMAISLAND_DEBUG"] != nil {
            NSLog("KramaIsland: panel resigned key (frontmost: %@)", NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")
        }
        if state.isLauncherOpen { state.closeLauncher() }
        if state.isShadeOpen { state.closeShade() }
    }

    /// Esc closes the shade (the launcher handles its own Esc through the text field).
    override func cancelOperation(_ sender: Any?) {
        if state.isShadeOpen { state.closeShade() }
        else if state.isLauncherOpen { state.closeLauncher() }
    }
}

/// Manages Dynamic Island panels across ALL connected displays (or the chosen display mode),
/// routing a single shared set of pointer monitors with zero per-display overhead.
final class NotchPanelManager {
    private let state: IslandState
    private var panels: [CGDirectDisplayID: NotchPanel] = [:]
    private var hiddenDisplayIDs: Set<CGDirectDisplayID> = []
    private var cancellables = Set<AnyCancellable>()

    private var globalMoveMonitor: Any?
    private var localMoveMonitor: Any?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var expandedGuardTimer: Timer?
    private var hoveredDisplayID: CGDirectDisplayID?
    // Zero-overhead drag pasteboard tracking: ZERO pasteboard IPC on normal mouse moves.
    // Captures baseline changeCount only on mouse-down/up so dragging a file near the notch
    // magnetically opens AirDrop | File Shelf with zero system lag (and never fires on window drags).
    private var baselineDragChangeCount: Int = NSPasteboard(name: .drag).changeCount
    private var cachedDragChangeCount: Int = -1
    private var dragHasShareableItems: Bool = false
    private var lastDragCheckTime: CFTimeInterval = 0
    private var wasDragging: Bool = false
    private var dragApproachDisplayID: CGDirectDisplayID?

    init(state: IslandState) {
        self.state = state

        state.onSurfaceSizeChanged = { [weak self] _ in
            self?.syncPointerState(driveHover: false)
        }

        Publishers.CombineLatest3(state.$layout, state.$activeDisplayID, state.$hiddenDisplayIDs)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in self?.layoutChanged() }
            .store(in: &cancellables)

        installPointerMonitors()
    }

    deinit {
        if let m = globalMoveMonitor { NSEvent.removeMonitor(m) }
        if let m = localMoveMonitor { NSEvent.removeMonitor(m) }
        if let m = globalClickMonitor { NSEvent.removeMonitor(m) }
        if let m = localClickMonitor { NSEvent.removeMonitor(m) }
        expandedGuardTimer?.invalidate()
        for panel in panels.values { panel.orderOut(nil) }
    }

    func show() {
        syncDisplays()
    }

    /// Reconciles active `NotchPanel` instances with `NotchGeometry.targetScreens` (handles
    /// multi-display hot-plug, display arrangement changes, Settings display picker, and size changes).
    func syncDisplays() {
        let targets = NotchGeometry.targetScreens
        let targetIDs = targets.map(\.displayID)
        let targetSet = Set(targetIDs)

        // Remove panels for displays that were unplugged or deselected.
        for (id, panel) in panels where !targetSet.contains(id) {
            panel.orderOut(nil)
            panel.close()
            panels.removeValue(forKey: id)
            state.renderedSurfaceSizes.removeValue(forKey: id)
        }

        // Create or reposition panels for every active target display.
        var nextGeos: [CGDirectDisplayID: NotchGeometry] = [:]
        for screen in targets {
            let geo = NotchGeometry(screen: screen)
            let id = geo.displayID
            nextGeos[id] = geo
            if let existing = panels[id] {
                existing.reposition(to: geo)
            } else {
                let panel = NotchPanel(state: state, geometry: geo)
                panels[id] = panel
                panel.setHiddenByPolicy(hiddenDisplayIDs.contains(id))
                panel.show()
            }
        }

        state.geometries = nextGeos
        state.managedDisplayIDs = targetIDs
        if !targetSet.contains(state.activeDisplayID), let first = targetIDs.first {
            state.activeDisplayID = first
        }
        updateVolumePolicyFlag()
        syncPointerState(driveHover: false)
    }

    /// Updates per-display visibility (hiding ONLY displays that currently show a full-screen video/app).
    func setHiddenDisplays(_ hidden: Set<CGDirectDisplayID>) {
        hiddenDisplayIDs = hidden
        state.hiddenDisplayIDs = hidden

        for (id, panel) in panels {
            panel.setHiddenByPolicy(hidden.contains(id))
        }

        // If every managed display is hidden, also dismiss transient Volume HUD & banners.
        let allHidden = !panels.isEmpty && panels.keys.allSatisfy { hidden.contains($0) }
        if allHidden {
            state.volume.dismissHUD()
            state.dismissBanner()
        }
        updateVolumePolicyFlag()
        syncPointerState(driveHover: false)
    }

    private func updateVolumePolicyFlag() {
        let allHidden = !panels.isEmpty && panels.keys.allSatisfy { hiddenDisplayIDs.contains($0) }
        VolumeController.shared.isIslandHiddenByPolicy = allHidden
    }

    private func layoutChanged() {
        var needsGuard = false
        for (id, panel) in panels {
            panel.applyLayoutOrder()
            let mode = state.layout(for: id).mode
            if mode == .expanded || mode == .volume || mode == .banner {
                needsGuard = true
            }
        }
        updateExpandedGuard(active: needsGuard)
        syncPointerState(driveHover: false)
    }

    // MARK: - Shared Pointer Tracking & Click-Through

    private func installPointerMonitors() {
        globalMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.handlePointerMove()
        }
        localMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.handlePointerMove()
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .leftMouseUp]) { [weak self] event in
            self?.handleClickEvent(event, isGlobal: true)
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            self?.handleClickEvent(event, isGlobal: false)
            return event
        }
    }

    private func handleClickEvent(_ event: NSEvent, isGlobal: Bool) {
        switch event.type {
        case .leftMouseDown:
            // Snapshot drag pasteboard baseline once when a click begins (zero IPC during normal mouse movement).
            baselineDragChangeCount = NSPasteboard(name: .drag).changeCount
            cachedDragChangeCount = -1
            dragHasShareableItems = false
            lastDragCheckTime = 0
            if isGlobal { closeOpenIslandIfClickOutside() }
        case .rightMouseDown:
            if isGlobal { closeOpenIslandIfClickOutside() }
        case .leftMouseUp:
            wasDragging = false
            dragHasShareableItems = false
            cachedDragChangeCount = -1
            baselineDragChangeCount = NSPasteboard(name: .drag).changeCount
            if let prev = dragApproachDisplayID {
                dragApproachDisplayID = nil
                if state.isDragTargeted {
                    state.setDragTargeted(false, on: prev)
                }
            }
            syncPointerState(driveHover: false)
        default:
            break
        }
    }

    private func closeOpenIslandIfClickOutside() {
        guard state.layout.isOpen, !state.isSizePreviewActive else { return }
        let pt = NSEvent.mouseLocation
        let insideAny = panels.values.contains { $0.isPointInsideIsland(pt) }
        if !insideAny {
            if state.isLauncherOpen { state.closeLauncher() }
            if state.isShadeOpen { state.closeShade() }
        }
    }

    private func handlePointerMove() {
        let dragging = NSEvent.pressedMouseButtons != 0
        if wasDragging && !dragging {
            wasDragging = false
            dragHasShareableItems = false
            cachedDragChangeCount = -1
            baselineDragChangeCount = NSPasteboard(name: .drag).changeCount
            if let prev = dragApproachDisplayID {
                dragApproachDisplayID = nil
                if state.isDragTargeted { state.setDragTargeted(false, on: prev) }
            }
        } else if dragging {
            wasDragging = true
        }

        let pt = NSEvent.mouseLocation

        // Fast nanosecond early-exit for normal mouse moves outside the top strip of every screen.
        if !dragging && !state.layout.isOpen && hoveredDisplayID == nil && dragApproachDisplayID == nil {
            let mode = state.layout.mode
            if mode != .volume && mode != .banner && AppSettings.shared.displayPreference != "cursor" {
                let nearAnyTop = panels.values.contains { panel in
                    guard !panel.hiddenByPolicy else { return false }
                    let sf = panel.geometry.screen.frame
                    return pt.y >= sf.maxY - 140 && pt.x >= sf.minX && pt.x <= sf.maxX
                }
                if !nearAnyTop { return }
            }
        }

        // In "Follow Cursor" mode, move the island automatically when the mouse enters another display.
        if AppSettings.shared.displayPreference == "cursor", !state.layout.isOpen {
            let cursorID = NotchGeometry.activeCursorScreen.displayID
            if panels[cursorID] == nil {
                syncDisplays()
            }
        }
        syncPointerState(driveHover: true, pointer: pt)
    }

    private func updateExpandedGuard(active: Bool) {
        if active {
            guard expandedGuardTimer == nil else { return }
            let t = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.syncPointerState(driveHover: true)
            }
            t.tolerance = 0.05
            expandedGuardTimer = t
        } else {
            expandedGuardTimer?.invalidate()
            expandedGuardTimer = nil
        }
    }

    private func syncPointerState(driveHover: Bool, pointer: NSPoint? = nil) {
        let pt = pointer ?? NSEvent.mouseLocation
        let dragging = NSEvent.pressedMouseButtons != 0
        let fileDragging = dragging && isFileDragActive()
        // Generous 56 pt magnetic wake radius when approaching with a dragged file; crisper 24 pt
        // exit radius once open so dragging away onto another app immediately restores click-through.
        let margin: CGFloat = fileDragging ? (state.isDragTargeted ? 24 : 56) : (dragging ? 18 : 0)

        if !fileDragging, let prevDragID = dragApproachDisplayID {
            dragApproachDisplayID = nil
            if state.isDragTargeted {
                state.setDragTargeted(false, on: prevDragID)
            }
        }

        var hitDisplayID: CGDirectDisplayID?
        for (id, panel) in panels {
            let inside = panel.isPointInsideIsland(pt, extraMargin: margin)
            if inside { hitDisplayID = id }
            let keepMouse = !panel.hiddenByPolicy && (
                inside
                || (state.activeDisplayID == id && state.isResizingIsland)
                || (state.layout(for: id).mode == .volume && state.volume.isScrubbingActive)
            )
            if panel.ignoresMouseEvents == keepMouse {
                panel.ignoresMouseEvents = !keepMouse
            }
        }

        guard driveHover, !state.layout.isOpen else { return }

        // Instant magnetic reveal of the AirDrop | File Shelf drop zones when dragging a file near the notch.
        if fileDragging, AppSettings.shared.airDropEnabled || AppSettings.shared.shelfEnabled {
            if let hit = hitDisplayID {
                if dragApproachDisplayID != hit || !state.isDragTargeted {
                    dragApproachDisplayID = hit
                    state.setDragTargeted(true, on: hit)
                }
                return
            } else if let prev = dragApproachDisplayID {
                dragApproachDisplayID = nil
                state.setDragTargeted(false, on: prev)
                return
            }
        }

        // Handle interactive Volume HUD / Notification Banner hover pause on whichever display hosts it.
        if let volID = panels.keys.first(where: { state.layout(for: $0).mode == .volume }) {
            let insideVol = (hitDisplayID == volID)
            state.volume.setHUDHovered(insideVol)
            if insideVol { hoveredDisplayID = nil; return }
        } else {
            state.volume.setHUDHovered(false)
        }

        if let bannerID = panels.keys.first(where: { state.layout(for: $0).mode == .banner }) {
            let insideBanner = (hitDisplayID == bannerID)
            state.setBannerHovered(insideBanner)
            if insideBanner { hoveredDisplayID = nil; return }
        } else {
            state.setBannerHovered(false)
        }

        if hitDisplayID != hoveredDisplayID {
            let previous = hoveredDisplayID
            hoveredDisplayID = hitDisplayID
            if let hit = hitDisplayID {
                state.setHovering(true, on: hit)
            } else if let prev = previous {
                state.setHovering(false, on: prev)
            }
        }
    }

    /// Ultra-lightweight check whether the active mouse drag carries a shareable file, folder, or image.
    /// Throttled to 60 ms until confirmed for the current drag session (then pure cached boolean),
    /// and never invoked while no mouse button is pressed.
    private func isFileDragActive() -> Bool {
        if dragHasShareableItems { return true }
        let now = CACurrentMediaTime()
        if now - lastDragCheckTime < 0.06 { return false }
        lastDragCheckTime = now

        let pb = NSPasteboard(name: .drag)
        let count = pb.changeCount
        guard count != baselineDragChangeCount else { return false }
        if count != cachedDragChangeCount {
            cachedDragChangeCount = count
            let types = pb.types ?? []
            dragHasShareableItems = types.contains { t in
                t == .fileURL
                    || t == .png
                    || t == .tiff
                    || t.rawValue == "public.file-url"
                    || t.rawValue == "NSFilenamesPboardType"
                    || t.rawValue == "public.image"
            }
        }
        return dragHasShareableItems
    }
}
