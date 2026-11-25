import AppKit
import Combine
import SwiftUI

/// Transparent, always-on-top, non-activating panel pinned to the top-centre of the notched screen.
///
/// The panel keeps a single fixed frame large enough for every island state and toggles
/// `ignoresMouseEvents` from live pointer hit-testing. Never resizing the NSWindow on hover
/// avoids backing-store reallocation freezes, coordinate-origin jumps, and AppKit tracking-area
/// flicker, while still passing every click outside the island straight through to apps below.
final class NotchPanel: NSPanel {
    private let state: IslandState
    private var cancellables = Set<AnyCancellable>()
    private var globalMoveMonitor: Any?
    private var localMoveMonitor: Any?
    private var globalClickMonitor: Any?
    private var expandedGuardTimer: Timer?
    private var hiddenByPolicy = false
    private var isPointerInside = false

    private static let fixedWidth: CGFloat = IslandLayout.launcherWidth + 68
    private static let fixedHeight: CGFloat = 820

    init(state: IslandState) {
        self.state = state
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)

        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        appearance = NSAppearance(named: .darkAqua)   // text fields, menus and carets match the black surface
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        ignoresMouseEvents = true

        let hosting = NSHostingView(rootView: NotchView(state: state))
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        contentView = hosting

        state.onSurfaceSizeChanged = { [weak self] in
            self?.syncPointerState(driveHover: false)
        }

        state.$layout
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] layout in self?.layoutChanged(layout) }
            .store(in: &cancellables)

        installPointerMonitors()
    }

    deinit {
        if let m = globalMoveMonitor { NSEvent.removeMonitor(m) }
        if let m = localMoveMonitor { NSEvent.removeMonitor(m) }
        if let m = globalClickMonitor { NSEvent.removeMonitor(m) }
        expandedGuardTimer?.invalidate()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show() {
        reposition()
        orderFrontRegardless()
        syncPointerState(driveHover: false)
    }

    /// Hidden over full-screen apps / listed apps (see Settings → Visibility).
    func setHiddenByPolicy(_ hidden: Bool) {
        guard hidden != hiddenByPolicy else { return }
        hiddenByPolicy = hidden
        if hidden {
            ignoresMouseEvents = true
            isPointerInside = false
            state.setHovering(false)
            orderOut(nil)
        } else {
            reposition()
            orderFrontRegardless()
            syncPointerState(driveHover: false)
        }
    }

    /// Called at launch and when screen configuration changes. Never called on hover.
    func reposition() {
        let geo = NotchGeometry.current
        state.geometry = geo
        let sf = geo.screen.frame
        let height = min(Self.fixedHeight, sf.height)
        let target = NSRect(x: (sf.midX - Self.fixedWidth / 2).rounded(),
                            y: sf.maxY - height,
                            width: Self.fixedWidth,
                            height: height)
        if frame != target {
            setFrame(target, display: false)
        }
        guard !hiddenByPolicy else { return }
        if state.layout.isOpen {
            makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            orderFrontRegardless()
        }
    }

    private func layoutChanged(_ layout: IslandLayout) {
        guard !hiddenByPolicy else { return }
        if layout.isOpen {
            makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            orderFrontRegardless()
        }
        updateExpandedGuard(active: layout.mode == .expanded || layout.mode == .volume || layout.mode == .banner)
        syncPointerState(driveHover: false)
    }

    // MARK: - Pointer tracking & click-through

    private func installPointerMonitors() {
        globalMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.syncPointerState(driveHover: true)
        }
        localMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.syncPointerState(driveHover: true)
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.state.layout.isOpen else { return }
            if !self.isPointInsideIsland(NSEvent.mouseLocation) {
                if self.state.isLauncherOpen { self.state.closeLauncher() }
                if self.state.isShadeOpen { self.state.closeShade() }
            }
        }
    }

    /// Fallback check only while expanded, so the island never stays stuck open if a system menu
    /// or Space switch swallows a mouseMoved event. Runs zero work when collapsed.
    private func updateExpandedGuard(active: Bool) {
        if active {
            guard expandedGuardTimer == nil else { return }
            expandedGuardTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                self?.syncPointerState(driveHover: true)
            }
        } else {
            expandedGuardTimer?.invalidate()
            expandedGuardTimer = nil
        }
    }

    private func syncPointerState(driveHover: Bool) {
        guard !hiddenByPolicy else { return }
        let pt = NSEvent.mouseLocation
        let dragging = NSEvent.pressedMouseButtons != 0
        let inside = isPointInsideIsland(pt, extraMargin: dragging ? 18 : 0)
        let shouldAcceptMouse = inside || state.isDragTargeted || state.volume.isScrubbingActive
        if ignoresMouseEvents == shouldAcceptMouse {
            ignoresMouseEvents = !shouldAcceptMouse
        }
        guard driveHover, !state.layout.isOpen else { return }
        if state.layout.mode == .volume {
            // Let the user hover, click Mute, or drag the Volume HUD bar without jumping into
            // the expanded hover panel.
            state.volume.setHUDHovered(inside)
            if !inside && isPointerInside {
                isPointerInside = false
            }
            return
        } else {
            state.volume.setHUDHovered(false)
        }
        if state.layout.mode == .banner {
            // Pause banner auto-dismiss and reveal quick actions cleanly without jumping into expanded hover.
            state.setBannerHovered(inside)
            if !inside && isPointerInside {
                isPointerInside = false
            }
            return
        } else {
            state.setBannerHovered(false)
        }
        if inside != isPointerInside {
            isPointerInside = inside
            state.setHovering(inside)
        }
    }

    private func isPointInsideIsland(_ pt: NSPoint, extraMargin: CGFloat = 0) -> Bool {
        let geo = state.geometry
        let sf = geo.screen.frame
        let layout = state.layout
        let rendered = state.renderedSurfaceSize

        let width: CGFloat
        let height: CGFloat
        let horizontalPad: CGFloat
        let bottomPad: CGFloat

        switch layout.mode {
        case .collapsed, .compact:
            width = max(layout.surfaceWidth(geo), rendered.width)
            height = max(geo.notchHeight, rendered.height)
            horizontalPad = 6 + extraMargin
            bottomPad = 4 + extraMargin
        default:
            width = max(layout.surfaceWidth(geo), rendered.width)
            height = max(geo.notchHeight + 36, rendered.height)
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
