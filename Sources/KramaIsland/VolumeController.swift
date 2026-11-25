import AppKit
import AudioToolbox
import CoreAudio
import CoreGraphics
import SwiftUI

/// Native CoreAudio volume engine + hardware volume-key interceptor.
///
/// - Replaces slow AppleScript polling with real-time CoreAudio property listeners (<1 ms).
/// - Intercepts hardware Volume Up / Volume Down / Mute keys (`NX_SYSDEFINED`) via a dedicated
///   `CGEventTap` (trying `.cghidEventTap` first, then `.cgSessionEventTap`) so macOS never shows
///   its original Volume OSD when KramaIsland is active.
/// - Drives the Dynamic Island's interactive `VolumeHUDView`, `InlineVolumeRow`, and Shade sliders
///   at 120 fps with smooth spring interpolation and elastic limit feedback.
final class VolumeController: ObservableObject {
    static let shared = VolumeController()

    // MARK: - Published UI State

    @Published private(set) var volume: Double = 0.5
    @Published private(set) var isMuted: Bool = false
    @Published private(set) var isControlSupported: Bool = true
    @Published private(set) var deviceName: String = "Output"
    @Published private(set) var deviceSymbol: String = "speaker.wave.2.fill"
    @Published private(set) var isHUDVisible: Bool = false
    @Published private(set) var isInterceptingKeys: Bool = false
    /// Incremented when the user hits the 0% or 100% cap so the bar performs a crisp elastic nudge.
    @Published private(set) var limitBumpToken: Int = 0
    @Published private(set) var limitBumpDirection: CGFloat = 0

    /// Effective displayed level (0 when muted so bars collapse smoothly to empty).
    var effectiveVolume: Double { isMuted ? 0 : volume }

    /// Dynamic speaker glyph matching current level and mute state.
    var speakerSymbol: String {
        if !isControlSupported { return "speaker.slash.fill" }
        if isMuted || volume <= 0.001 { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    /// True while the island panel is hidden by Visibility rules (fullscreen / hidden apps), in which
    /// case hardware volume keys pass through to macOS so the user isn't left without any HUD.
    var isIslandHiddenByPolicy: Bool = false

    // MARK: - Private State

    private var started = false
    private var outputDevice: AudioObjectID = kAudioObjectUnknown
    private var defaultDeviceBlock: AudioObjectPropertyListenerBlock?
    private var deviceListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?

    private var hideWork: DispatchWorkItem?
    private var isHUDHovered = false
    private(set) var isScrubbingActive = false
    private var suppressExternalEchoUntil = Date.distantPast
    private var lastNonZeroVolume: Double = 0.25
    private var lastHapticAt = Date.distantPast
    private var lastSoundAt = Date.distantPast
    private lazy var feedbackSound: NSSound? = {
        let path = "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return NSSound(contentsOfFile: path, byReference: true)
    }()

    private static let standardStep: Double = 1.0 / 16.0
    private static let fineStep: Double = 1.0 / 64.0
    private static let hudDuration: TimeInterval = 1.65

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !started else {
            syncEventTap()
            return
        }
        started = true
        installSystemDeviceListener()
        bindDefaultOutputDevice(announce: false)
        syncEventTap()
    }

    func stop() {
        guard started else { return }
        started = false
        stopEventTap()
        removeDeviceListeners()
        removeSystemDeviceListener()
        hideWork?.cancel()
        hideWork = nil
        if isHUDVisible {
            withAnimation(Motion.quick) { isHUDVisible = false }
        }
    }

    /// Re-evaluates whether the hardware volume key tap should be active (called when Accessibility
    /// changes or Settings toggle flips).
    func syncEventTap() {
        let s = AppSettings.shared
        let wantsTap = started && s.volumeHUDEnabled && s.replaceSystemVolumeHUD
        if wantsTap {
            if tap == nil {
                startEventTap()
            } else if let tap, !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
                updateInterceptingFlag(true)
            }
        } else {
            stopEventTap()
        }
    }

    func rearmTapIfNeeded() {
        let s = AppSettings.shared
        guard started, s.volumeHUDEnabled, s.replaceSystemVolumeHUD else {
            stopEventTap()
            return
        }
        if AXIsProcessTrusted() {
            if tap == nil {
                startEventTap()
            } else if let tap, !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
                updateInterceptingFlag(true)
            }
        } else {
            stopEventTap()
        }
    }

    // MARK: - Public Controls (Main Thread)

    /// Sets system output volume directly via CoreAudio (`0.0 ... 1.0`).
    /// - Parameters:
    ///   - fraction: target scalar volume
    ///   - showHUD: whether to show/extend the Dynamic Island Volume HUD
    ///   - fromScrub: true while continuously dragging a slider
    func setVolume(_ fraction: Double, showHUD: Bool = false, fromScrub: Bool = false) {
        let clamped = min(max(fraction, 0), 1)
        guard outputDevice != kAudioObjectUnknown else { return }
        if !isControlSupported {
            if showHUD { presentHUD() }
            return
        }

        suppressExternalEchoUntil = Date().addingTimeInterval(0.25)
        let shouldUnmute = clamped > 0.001 && isMuted
        if shouldUnmute {
            writeMute(false, to: outputDevice)
        }
        writeVolume(Float32(clamped), to: outputDevice)
        if clamped <= 0.001 {
            writeMute(true, to: outputDevice)
        }

        if clamped > 0.01 { lastNonZeroVolume = clamped }
        isMuted = clamped <= 0.001
        volume = clamped

        if showHUD {
            presentHUD()
        }
        if !fromScrub {
            tapHaptic(.alignment)
        }
    }

    /// Steps volume up or down (used by hardware keys and quick actions).
    func step(up: Bool, fine: Bool = false, shiftPressed: Bool = false, showHUD: Bool = true) {
        guard outputDevice != kAudioObjectUnknown else { return }
        if !isControlSupported {
            triggerLimitBump(direction: up ? 1 : -1)
            if showHUD { presentHUD() }
            return
        }

        let delta = fine ? Self.fineStep : Self.standardStep
        let current = isMuted ? 0.0 : volume
        var target: Double

        if up {
            if isMuted && volume > 0.001 {
                // Pressing Volume Up while muted restores and steps smoothly, matching macOS.
                target = fine ? min(1, volume + delta) : min(1, ceil((volume + 0.0001) * 16.0) / 16.0)
            } else if fine {
                target = min(1, current + delta)
            } else {
                target = min(1, (round(current * 16.0) + 1.0) / 16.0)
            }
            if !isMuted && current >= 0.999 {
                triggerLimitBump(direction: 1)
                playVolumeClickIfNeeded(shiftPressed: shiftPressed, fine: fine)
                if showHUD { presentHUD() }
                return
            }
        } else {
            if isMuted || current <= 0.001 {
                triggerLimitBump(direction: -1)
                if showHUD { presentHUD() }
                return
            }
            if fine {
                target = max(0, current - delta)
            } else {
                target = max(0, (round(current * 16.0) - 1.0) / 16.0)
            }
        }

        suppressExternalEchoUntil = Date().addingTimeInterval(0.25)
        let nowMuted = target <= 0.001
        if nowMuted {
            writeVolume(0, to: outputDevice)
            writeMute(true, to: outputDevice)
        } else {
            if isMuted { writeMute(false, to: outputDevice) }
            writeVolume(Float32(target), to: outputDevice)
            lastNonZeroVolume = target
        }

        withAnimation(.interactiveSpring(response: 0.16, dampingFraction: 0.86)) {
            self.isMuted = nowMuted
            self.volume = target
        }
        tapHaptic(.alignment)
        playVolumeClickIfNeeded(shiftPressed: shiftPressed, fine: fine)
        if showHUD { presentHUD() }
    }

    /// Toggles system mute cleanly.
    func toggleMute(showHUD: Bool = true) {
        guard outputDevice != kAudioObjectUnknown else { return }
        if !isControlSupported {
            triggerLimitBump(direction: -1)
            if showHUD { presentHUD() }
            return
        }

        suppressExternalEchoUntil = Date().addingTimeInterval(0.25)
        let targetMute = !isMuted
        if targetMute {
            if volume > 0.01 { lastNonZeroVolume = volume }
            writeMute(true, to: outputDevice)
            withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.85)) {
                self.isMuted = true
            }
        } else {
            writeMute(false, to: outputDevice)
            var restored = volume
            if restored <= 0.001 {
                restored = max(Self.standardStep, lastNonZeroVolume)
                writeVolume(Float32(restored), to: outputDevice)
            }
            withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.85)) {
                self.isMuted = false
                self.volume = restored
            }
        }
        tapHaptic(.levelChange)
        if showHUD { presentHUD() }
    }

    // MARK: - HUD Visibility & Interaction

    func presentHUD(duration: TimeInterval = VolumeController.hudDuration) {
        guard AppSettings.shared.volumeHUDEnabled else { return }
        if !isHUDVisible {
            withAnimation(Motion.spring) { isHUDVisible = true }
        }
        scheduleHide(after: duration)
    }

    func dismissHUD() {
        hideWork?.cancel()
        hideWork = nil
        isHUDHovered = false
        isScrubbingActive = false
        if isHUDVisible {
            withAnimation(Motion.quick) { isHUDVisible = false }
        }
    }

    func setHUDHovered(_ hovering: Bool) {
        guard hovering != isHUDHovered else { return }
        isHUDHovered = hovering
        if hovering {
            hideWork?.cancel()
            hideWork = nil
        } else if !isScrubbingActive, isHUDVisible {
            scheduleHide(after: 0.75)
        }
    }

    func setScrubbing(_ scrubbing: Bool) {
        guard scrubbing != isScrubbingActive else { return }
        isScrubbingActive = scrubbing
        if scrubbing {
            hideWork?.cancel()
            hideWork = nil
        } else if !isHUDHovered, isHUDVisible {
            scheduleHide(after: 0.9)
        }
    }

    /// Demo/preview helper for `KRAMAISLAND_PREVIEW=volume`.
    func demoHUD() {
        volume = 0.68
        isMuted = false
        presentHUD(duration: 20)
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideWork?.cancel()
        guard !isHUDHovered, !isScrubbingActive else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isHUDHovered, !self.isScrubbingActive else { return }
            withAnimation(Motion.quick) { self.isHUDVisible = false }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func triggerLimitBump(direction: CGFloat) {
        limitBumpDirection = direction
        limitBumpToken &+= 1
        tapHaptic(.levelChange)
    }

    private func tapHaptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard AppSettings.shared.haptics else { return }
        let now = Date()
        guard now.timeIntervalSince(lastHapticAt) > 0.045 else { return }
        lastHapticAt = now
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    private func playVolumeClickIfNeeded(shiftPressed: Bool, fine: Bool) {
        let systemPref = UserDefaults(suiteName: "NSGlobalDomain")?.bool(forKey: "com.apple.sound.beep.feedback") ?? false
        let baseEnabled = AppSettings.shared.volumeFeedbackSound || systemPref
        // Holding Shift alone temporarily flips the volume feedback click, matching macOS.
        let shouldPlay = (!fine && shiftPressed) ? !baseEnabled : baseEnabled
        guard shouldPlay, let sound = feedbackSound else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSoundAt) > 0.055 else { return }
        lastSoundAt = now
        sound.stop()
        sound.play()
    }

    // MARK: - Hardware Volume Key Interception (CGEventTap)

    private func startEventTap() {
        stopEventTap()
        // NX_SYSDEFINED = 14 (carries hardware Volume Up / Down / Mute auxiliary key events).
        let mask = CGEventMask(1 << 14)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // Prefer `.cghidEventTap` so we intercept volume keys before BezelServices / ControlCenter
        // can ever display the original macOS Volume OSD; fall back to `.cgSessionEventTap`.
        var tapLocation = "hid"
        let created: CFMachPort?
        if let hid = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: volumeKeyTapCallback,
            userInfo: refcon
        ) {
            created = hid
        } else {
            tapLocation = "session"
            created = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: volumeKeyTapCallback,
                userInfo: refcon
            )
        }

        guard let created else {
            NSLog("KramaIsland volume: event tap unavailable (Accessibility required to hide native macOS volume HUD)")
            updateInterceptingFlag(false)
            return
        }

        tap = created
        let source = CFMachPortCreateRunLoopSource(nil, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        tapSource = source
        CGEvent.tapEnable(tap: created, enable: true)
        updateInterceptingFlag(true)
        NSLog("KramaIsland volume: hardware volume key interceptor active (%@ tap)", tapLocation)
    }

    private func stopEventTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
        updateInterceptingFlag(false)
    }

    private func updateInterceptingFlag(_ active: Bool) {
        if Thread.isMainThread {
            if isInterceptingKeys != active { isInterceptingKeys = active }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isInterceptingKeys != active else { return }
                self.isInterceptingKeys = active
            }
        }
    }

    /// Called on the main run loop for `NX_SYSDEFINED` events. Returns `true` to swallow the event
    /// so macOS does not show its native Volume UI.
    fileprivate func handleTapEvent(_ event: CGEvent, type: CGEventType) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard type.rawValue == 14 else { return false }
        guard AppSettings.shared.volumeHUDEnabled,
              AppSettings.shared.replaceSystemVolumeHUD,
              !isIslandHiddenByPolicy else {
            return false
        }

        guard let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == 8 else { // NX_SUBTYPE_AUX_CONTROL_BUTTONS
            return false
        }

        let data1 = nsEvent.data1
        let keyCode = (data1 & 0xFFFF0000) >> 16
        // NX_KEYTYPE_SOUND_UP = 0, NX_KEYTYPE_SOUND_DOWN = 1, NX_KEYTYPE_MUTE = 7
        guard keyCode == 0 || keyCode == 1 || keyCode == 7 else { return false }

        let flags = event.flags
        // Preserve Cmd/Ctrl shortcuts and Option-alone (macOS opens Sound Settings).
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { return false }
        let option = flags.contains(.maskAlternate)
        let shift = flags.contains(.maskShift)
        if option && !shift { return false }

        let keyFlags = data1 & 0x0000FFFF
        let keyState = (keyFlags & 0xFF00) >> 8   // 0xA = down, 0xB = up
        let isRepeat = (keyFlags & 0x1) != 0

        if keyState == 0xA {
            let fine = option && shift
            if keyCode == 0 {
                DispatchQueue.main.async { self.step(up: true, fine: fine, shiftPressed: shift) }
            } else if keyCode == 1 {
                DispatchQueue.main.async { self.step(up: false, fine: fine, shiftPressed: shift) }
            } else if keyCode == 7 && !isRepeat {
                DispatchQueue.main.async { self.toggleMute(showHUD: true) }
            }
            return true
        } else if keyState == 0xB {
            // Swallow key-up as well so macOS doesn't react to an unmatched release.
            return true
        }
        return false
    }

    // MARK: - CoreAudio Plumbing

    private func installSystemDeviceListener() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.bindDefaultOutputDevice(announce: false)
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block) == noErr {
            defaultDeviceBlock = block
        }
    }

    private func removeSystemDeviceListener() {
        guard let block = defaultDeviceBlock else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
        defaultDeviceBlock = nil
    }

    private func bindDefaultOutputDevice(announce: Bool) {
        let dev = readDefaultOutputDevice()
        if dev != outputDevice {
            removeDeviceListeners()
            outputDevice = dev
            if dev != kAudioObjectUnknown {
                installDeviceListeners(on: dev)
            }
        }
        refreshFromHardware(announce: announce)
    }

    private func installDeviceListeners(on device: AudioObjectID) {
        let addresses: [AudioObjectPropertyAddress] = [
            AudioObjectPropertyAddress(
                mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: 1
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDataSource,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyJackIsConnected,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            ),
        ]

        for var addr in addresses where AudioObjectHasProperty(device, &addr) {
            let selector = addr.mSelector
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                let isVolumeChange = selector == kAudioHardwareServiceDeviceProperty_VirtualMainVolume
                    || selector == kAudioDevicePropertyVolumeScalar
                    || selector == kAudioDevicePropertyMute
                let shouldAnnounce = isVolumeChange && Date() >= self.suppressExternalEchoUntil
                self.refreshFromHardware(announce: shouldAnnounce)
            }
            if AudioObjectAddPropertyListenerBlock(device, &addr, .main, block) == noErr {
                deviceListeners.append((addr, block))
            }
        }
    }

    private func removeDeviceListeners() {
        guard outputDevice != kAudioObjectUnknown else {
            deviceListeners.removeAll()
            return
        }
        for (addr, block) in deviceListeners {
            var mutable = addr
            AudioObjectRemovePropertyListenerBlock(outputDevice, &mutable, .main, block)
        }
        deviceListeners.removeAll()
    }

    private func refreshFromHardware(announce: Bool) {
        guard outputDevice != kAudioObjectUnknown else { return }
        let name = readDeviceName(outputDevice)
        let transport = readTransportType(outputDevice)
        let symbol = Self.symbol(for: name, transport: transport)
        let supported = isVolumeWritable(outputDevice)
        let hwVol = readVolume(outputDevice)
        let hwMute = readMute(outputDevice) ?? (hwVol <= 0.001)

        if name != deviceName { deviceName = name }
        if symbol != deviceSymbol { deviceSymbol = symbol }
        if supported != isControlSupported { isControlSupported = supported }

        let changed = abs(hwVol - volume) > 0.002 || hwMute != isMuted
        if hwVol > 0.01 { lastNonZeroVolume = hwVol }

        if changed {
            withAnimation(.interactiveSpring(response: 0.16, dampingFraction: 0.86)) {
                self.volume = hwVol
                self.isMuted = hwMute
            }
            if announce {
                presentHUD()
            }
        }
    }

    private func readDefaultOutputDevice() -> AudioObjectID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else {
            return kAudioObjectUnknown
        }
        return dev
    }

    private func readDeviceName(_ device: AudioObjectID) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &unmanaged) == noErr,
           let cf = unmanaged?.takeRetainedValue() {
            return cf as String
        }
        return "Output"
    }

    private func readTransportType(_ device: AudioObjectID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &transport) == noErr else { return 0 }
        return transport
    }

    private func isVolumeWritable(_ device: AudioObjectID) -> Bool {
        var virtualAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(device, &virtualAddr) {
            var settable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(device, &virtualAddr, &settable) == noErr, settable.boolValue {
                return true
            }
        }
        for channel: UInt32 in [0, 1, 2] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: channel
            )
            if AudioObjectHasProperty(device, &addr) {
                var settable: DarwinBoolean = false
                if AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue {
                    return true
                }
            }
        }
        return false
    }

    private func readVolume(_ device: AudioObjectID) -> Double {
        var virtualAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(device, &virtualAddr) {
            var vol: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &virtualAddr, 0, nil, &size, &vol) == noErr {
                return Double(min(max(vol, 0), 1))
            }
        }
        var mainAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(device, &mainAddr) {
            var vol: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &mainAddr, 0, nil, &size, &vol) == noErr {
                return Double(min(max(vol, 0), 1))
            }
        }
        var sum: Double = 0
        var count: Double = 0
        for ch: UInt32 in [1, 2] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: ch
            )
            var vol: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectHasProperty(device, &addr),
               AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &vol) == noErr {
                sum += Double(min(max(vol, 0), 1))
                count += 1
            }
        }
        return count > 0 ? sum / count : 0.5
    }

    private func writeVolume(_ value: Float32, to device: AudioObjectID) {
        var vol = min(max(value, 0), 1)
        let size = UInt32(MemoryLayout<Float32>.size)
        var virtualAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var settable: DarwinBoolean = false
        if AudioObjectHasProperty(device, &virtualAddr),
           AudioObjectIsPropertySettable(device, &virtualAddr, &settable) == noErr,
           settable.boolValue {
            AudioObjectSetPropertyData(device, &virtualAddr, 0, nil, size, &vol)
            return
        }
        var mainAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(device, &mainAddr),
           AudioObjectIsPropertySettable(device, &mainAddr, &settable) == noErr,
           settable.boolValue {
            AudioObjectSetPropertyData(device, &mainAddr, 0, nil, size, &vol)
            return
        }
        for ch: UInt32 in [1, 2] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: ch
            )
            if AudioObjectHasProperty(device, &addr),
               AudioObjectIsPropertySettable(device, &addr, &settable) == noErr,
               settable.boolValue {
                AudioObjectSetPropertyData(device, &addr, 0, nil, size, &vol)
            }
        }
    }

    private func readMute(_ device: AudioObjectID) -> Bool? {
        for ch: UInt32 in [0, 1] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: ch
            )
            if AudioObjectHasProperty(device, &addr) {
                var muted: UInt32 = 0
                var size = UInt32(MemoryLayout<UInt32>.size)
                if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &muted) == noErr {
                    return muted != 0
                }
            }
        }
        return nil
    }

    private func writeMute(_ mute: Bool, to device: AudioObjectID) {
        var val: UInt32 = mute ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        var settable: DarwinBoolean = false

        var mainAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(device, &mainAddr),
           AudioObjectIsPropertySettable(device, &mainAddr, &settable) == noErr,
           settable.boolValue {
            AudioObjectSetPropertyData(device, &mainAddr, 0, nil, size, &val)
            return
        }
        for ch: UInt32 in [1, 2] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: ch
            )
            if AudioObjectHasProperty(device, &addr),
               AudioObjectIsPropertySettable(device, &addr, &settable) == noErr,
               settable.boolValue {
                AudioObjectSetPropertyData(device, &addr, 0, nil, size, &val)
            }
        }
    }

    private static func symbol(for name: String, transport: UInt32) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("beats") { return "beats.headphones" }
        if lower.contains("homepod") { return "homepod.fill" }
        if lower.contains("headphone") || lower.contains("earbud") || lower.contains("buds") {
            return "headphones"
        }
        if lower.contains("display") || lower.contains("tv")
            || transport == kAudioDeviceTransportTypeHDMI
            || transport == kAudioDeviceTransportTypeDisplayPort {
            return "display"
        }
        if transport == kAudioDeviceTransportTypeAirPlay {
            return "airplayaudio"
        }
        if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE {
            return "hifispeaker.fill"
        }
        if lower.contains("macbook") || lower.contains("speaker") || transport == kAudioDeviceTransportTypeBuiltIn {
            return "hifispeaker.fill"
        }
        return "speaker.wave.2.fill"
    }
}

private func volumeKeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<VolumeController>.fromOpaque(refcon).takeUnretainedValue()
    return controller.handleTapEvent(event, type: type) ? nil : Unmanaged.passUnretained(event)
}

// MARK: - Dynamic Island Volume HUD

/// Flagship Dynamic Island Volume HUD drawn cleanly under the notch.
///
/// Features:
/// - Clickable dynamic speaker badge to toggle Mute immediately.
/// - Active output device name + tabular monospaced percentage with smooth numeric transition.
/// - Liquid-smooth interactive volume track (drag or click to scrub, elastic bounce at 0%/100%).
struct VolumeHUDView: View {
    @ObservedObject var volume: VolumeController
    @ObservedObject private var settings = AppSettings.shared
    @State private var barHovering = false
    @State private var dragging = false
    @State private var bumpOffset: CGFloat = 0
    @State private var bumpStretch: CGFloat = 1

    private var isMutedState: Bool { volume.isMuted || volume.volume <= 0.001 || !volume.isControlSupported }
    private var percent: Int { Int((volume.effectiveVolume * 100).rounded()) }

    private var barFillColor: Color {
        if !volume.isControlSupported || isMutedState {
            return .white.opacity(0.32)
        }
        let accent = Theme.accent
        return settings.accentHex.uppercased() == "#FFFFFF" ? .white : accent
    }

    private var iconTint: Color {
        if !volume.isControlSupported { return UI.secondaryText }
        if isMutedState { return UI.danger }
        return .white
    }

    var body: some View {
        HStack(spacing: 12) {
            // Click-to-mute dynamic speaker badge
            Button {
                volume.toggleMute(showHUD: true)
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isMutedState && volume.isControlSupported
                              ? UI.danger.opacity(0.18)
                              : Color.white.opacity(0.11))
                    Image(systemName: volume.speakerSymbol)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(iconTint)
                        .modifier(SmoothSymbolReplace())
                }
                .frame(width: 34, height: 34)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            isMutedState && volume.isControlSupported
                            ? UI.danger.opacity(0.35)
                            : Color.white.opacity(0.10),
                            lineWidth: 0.75
                        )
                )
            }
            .buttonStyle(.plain)
            .help(volume.isMuted ? "Unmute" : "Mute")

            // Output caption, percentage, and interactive smooth track
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    Image(systemName: volume.deviceSymbol)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(UI.secondaryText)
                    Text(volume.deviceName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.86))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(statusReadout)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(isMutedState && volume.isControlSupported ? UI.danger : .white.opacity(0.92))
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.12), value: percent)
                }

                if volume.isControlSupported {
                    interactiveTrack
                } else {
                    Text("Volume controlled by output device")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(UI.secondaryText)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 13)
        .onChange(of: volume.limitBumpToken) { _ in
            guard !Motion.reduce else { return }
            let dir = volume.limitBumpDirection
            withAnimation(.spring(response: 0.14, dampingFraction: 0.55)) {
                bumpOffset = dir * 3.0
                bumpStretch = 1.022
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.72)) {
                    bumpOffset = 0
                    bumpStretch = 1.0
                }
            }
        }
    }

    private var statusReadout: String {
        if !volume.isControlSupported { return "Fixed" }
        if isMutedState { return "Muted" }
        return "\(percent)%"
    }

    private var interactiveTrack: some View {
        let activeHeight: CGFloat = (barHovering || dragging) ? 9.5 : 7.0
        return GeometryReader { geo in
            let w = max(1, geo.size.width)
            let frac = CGFloat(min(max(volume.effectiveVolume, 0), 1))
            let fillWidth = w * frac

            ZStack(alignment: .leading) {
                // Recessed capsule track
                Capsule()
                    .fill(Color.white.opacity(0.15))
                    .overlay(
                        Capsule().strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
                    )

                // Luminous animated volume fill
                if fillWidth > 0.5 {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [barFillColor.opacity(0.86), barFillColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(activeHeight, fillWidth))
                        .shadow(color: barFillColor.opacity(dragging ? 0.35 : 0.18), radius: dragging ? 6 : 3)
                }

                // Subtle thumb cue while hovering or scrubbing
                if barHovering || dragging {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 13, height: 13)
                        .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                        .offset(x: min(max(0, fillWidth - 6.5), w - 13))
                        .transition(.opacity.combined(with: .scale(scale: 0.7)))
                }
            }
            .frame(height: activeHeight)
            .frame(maxHeight: .infinity)
            .scaleEffect(x: bumpStretch, y: 1 / max(0.96, bumpStretch), anchor: bumpOffset >= 0 ? .leading : .trailing)
            .offset(x: bumpOffset)
            .contentShape(Rectangle().inset(by: -8))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !dragging {
                            dragging = true
                            volume.setScrubbing(true)
                        }
                        let next = Double(min(max(value.location.x / w, 0), 1))
                        volume.setVolume(next, showHUD: true, fromScrub: true)
                    }
                    .onEnded { _ in
                        dragging = false
                        volume.setScrubbing(false)
                    }
            )
            .animation(.interactiveSpring(response: 0.16, dampingFraction: 0.86), value: volume.effectiveVolume)
        }
        .frame(height: 15)
        .onHover { barHovering = $0 }
        .animation(Motion.quick, value: barHovering)
        .animation(Motion.quick, value: dragging)
    }
}

/// Slim live volume strip revealed inside the hover (`.expanded`) view if the user adjusts volume
/// while hovering over the island.
struct InlineVolumeRow: View {
    @ObservedObject var volume: VolumeController

    var body: some View {
        HStack(spacing: 10) {
            Button { volume.toggleMute(showHUD: true) } label: {
                Image(systemName: volume.speakerSymbol)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(volume.isMuted ? UI.danger : .white)
                    .frame(width: 24, height: 24)
                    .background((volume.isMuted ? UI.danger : Color.white).opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .modifier(SmoothSymbolReplace())
            }
            .buttonStyle(.plain)

            VolumeSlider(volume: volume, compact: true)

            Text(volume.isMuted ? "Muted" : "\(Int((volume.effectiveVolume * 100).rounded()))%")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(volume.isMuted ? UI.danger : .white.opacity(0.86))
                .frame(width: 38, alignment: .trailing)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(UI.cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(UI.cardEdge, lineWidth: 1))
    }
}

/// Dedicated Sound & Volume card shown in the Shade when no Now Playing card is active, so users
/// always have smooth volume & output control inside the Dynamic Island.
struct ShadeVolumeCard: View {
    @ObservedObject var volume: VolumeController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: volume.deviceSymbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(UI.secondaryText)
                Text(volume.deviceName.uppercased())
                    .font(UI.eyebrow)
                    .tracking(0.6)
                    .foregroundStyle(UI.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(volume.isControlSupported
                     ? (volume.isMuted ? "Muted" : "\(Int((volume.effectiveVolume * 100).rounded()))%")
                     : "Fixed")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(volume.isMuted ? UI.danger : .white.opacity(0.86))
                    .contentTransition(.numericText())
            }
            VolumeSlider(volume: volume)
        }
        .islandCard(padding: 12)
    }
}

/// Smooth CoreAudio output-volume slider shared by `ShadeMediaCard`, `ShadeVolumeCard`, and
/// `InlineVolumeRow`. Supports click-to-mute on the left speaker icon and 120 fps dragging.
struct VolumeSlider: View {
    @ObservedObject var volume: VolumeController
    var compact: Bool = false
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        HStack(spacing: compact ? 8 : 10) {
            if !compact {
                Button { volume.toggleMute(showHUD: false) } label: {
                    Image(systemName: volume.isMuted || volume.volume <= 0.001 ? "speaker.slash.fill" : "speaker.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(volume.isMuted ? UI.danger : UI.secondaryText)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(volume.isMuted ? "Unmute" : "Mute")
            }

            GeometryReader { geo in
                let w = max(1, geo.size.width)
                let x = w * CGFloat(min(max(volume.effectiveVolume, 0), 1))
                let barHeight: CGFloat = (hovering || dragging) ? 6 : 4
                ZStack(alignment: .leading) {
                    Capsule().fill(UI.track).frame(height: barHeight)
                    Capsule()
                        .fill(volume.isMuted ? Color.white.opacity(0.32) : Color.white.opacity(0.92))
                        .frame(width: max(0, x), height: barHeight)
                    Circle()
                        .fill(.white)
                        .frame(width: 12, height: 12)
                        .offset(x: min(max(0, x - 6), w - 12))
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .opacity((hovering || dragging) && volume.isControlSupported ? 1 : 0)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle().inset(by: -8))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard volume.isControlSupported else { return }
                            dragging = true
                            volume.setVolume(Double(value.location.x / w), showHUD: false, fromScrub: true)
                        }
                        .onEnded { _ in dragging = false }
                )
                .animation(.interactiveSpring(response: 0.14, dampingFraction: 0.88), value: volume.effectiveVolume)
            }
            .frame(height: 14)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)

            if !compact {
                Button { volume.step(up: true, showHUD: false) } label: {
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(UI.secondaryText)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Increase volume")
            }
        }
        .opacity(volume.isControlSupported ? 1 : 0.45)
    }
}

private struct SmoothSymbolReplace: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.contentTransition(.symbolEffect(.replace))
        } else {
            content
        }
    }
}
