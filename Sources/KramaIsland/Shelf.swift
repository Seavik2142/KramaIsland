import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Zero-Delay AirDrop Manager

/// Coordinates macOS native AirDrop transfers cleanly without blocking Finder drags or the main UI.
///
/// - Pre-warms `NSSharingService(named: .sendViaAirDrop)` after launch so first-use XPC has zero lag.
/// - Retains active `NSSharingService` instances via `NSSharingServiceDelegate` until completion so
///   the AirDrop sheet never disappears prematurely.
/// - Cleans up temporary files (e.g. images dragged directly from browsers) after sharing finishes.
final class AirDropManager: NSObject, NSSharingServiceDelegate {
    static let shared = AirDropManager()

    private var activeServices: [ObjectIdentifier: (service: NSSharingService, tempURLs: [URL])] = [:]
    private var warmedUp = false

    private static let tempDirectory: URL = {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KramaIsland/AirDrop", isDirectory: true)
    }()

    /// Gently initializes the macOS AirDrop sharing service after launch so first drop is instant.
    func warmUp() {
        guard !warmedUp else { return }
        warmedUp = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            _ = NSSharingService(named: .sendViaAirDrop)
        }
    }

    /// Launches the native macOS AirDrop sheet for `urls` on the next run-loop turn so any active
    /// Finder drag session finishes cleanly with zero system lag.
    func send(_ urls: [URL], temporaryURLs: [URL] = []) {
        let normalized = urls.map { ($0 as NSURL).filePathURL ?? $0.standardizedFileURL }
        let valid = normalized.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !valid.isEmpty else {
            cleanupTemp(temporaryURLs)
            return
        }

        // Dispatch asynchronously so drag-and-drop completion returns immediately to Finder.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            IslandState.shared?.suppressHover(for: 0.75)

            guard let service = NSSharingService(named: .sendViaAirDrop),
                  service.canPerform(withItems: valid) else {
                self.cleanupTemp(temporaryURLs)
                ActivityCenter.shared.show(LiveActivity(
                    id: "airdrop.unavailable",
                    kind: .custom,
                    symbol: "dot.radiowaves.left.and.right",
                    title: "AirDrop Unavailable",
                    subtitle: "Turn on Wi-Fi & Bluetooth to share",
                    progress: nil,
                    tint: UI.warning,
                    duration: 3.2
                ))
                return
            }
            service.delegate = self
            let key = ObjectIdentifier(service)
            self.activeServices[key] = (service, temporaryURLs)

            Feedback.tap()
            let label = valid.count == 1
                ? valid[0].lastPathComponent
                : "\(valid.count) files ready"
            ActivityCenter.shared.show(LiveActivity(
                id: "airdrop.send",
                kind: .custom,
                symbol: "dot.radiowaves.left.and.right",
                title: "AirDrop",
                subtitle: label,
                progress: nil,
                tint: UI.info,
                duration: 2.0
            ))

            NSApp.activate(ignoringOtherApps: true)
            service.perform(withItems: valid)
        }
    }

    /// Opens a crisp multi-file picker and sends selected files/folders directly via AirDrop.
    func pickAndSendFiles() {
        DispatchQueue.main.async { [weak self] in
            let panel = NSOpenPanel()
            panel.title = "AirDrop Files"
            panel.message = "Choose files or folders to share via AirDrop"
            panel.prompt = "AirDrop"
            panel.allowsMultipleSelection = true
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            NSApp.activate(ignoringOtherApps: true)
            panel.begin { [weak self] response in
                guard response == .OK, !panel.urls.isEmpty else { return }
                self?.send(panel.urls)
            }
        }
    }

    /// Opens macOS Finder's native AirDrop window immediately (zero AppleScript).
    func openAirDropWindow() {
        let appURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if FileManager.default.fileExists(atPath: appURL.path) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: config)
        } else if let fallback = URL(string: "nwnode://domain-AirDrop") {
            NSWorkspace.shared.open(fallback)
        }
        Feedback.tap()
    }

    /// Writes dragged in-memory image data into Caches off the main thread for instant AirDrop.
    static func writeTempImage(_ data: Data, suggestedName: String? = nil) -> URL? {
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let base = (suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? suggestedName!
            : "Image-\(Int(Date().timeIntervalSince1970))"
        let safe = base.replacingOccurrences(of: "/", with: "-")
        let filename = safe.lowercased().hasSuffix(".png") ? safe : "\(safe).png"
        let dest = tempDirectory.appendingPathComponent(filename)

        if let rep = NSBitmapImageRep(data: data),
           let png = rep.representation(using: .png, properties: [:]) {
            do { try png.write(to: dest, options: .atomic); return dest } catch { return nil }
        }
        do { try data.write(to: dest, options: .atomic); return dest } catch { return nil }
    }

    // MARK: - NSSharingServiceDelegate

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        let key = ObjectIdentifier(sharingService)
        let entry = activeServices.removeValue(forKey: key)
        if let temps = entry?.tempURLs {
            // Give AirDrop a brief moment to finish reading before removing cached temp files.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.cleanupTemp(temps)
            }
        }
        Feedback.tap()
        ActivityCenter.shared.show(LiveActivity(
            id: "airdrop.done",
            kind: .custom,
            symbol: "checkmark.circle.fill",
            title: "Sent via AirDrop",
            subtitle: items.count == 1 ? "Transfer complete" : "\(items.count) items sent",
            progress: nil,
            tint: UI.success,
            duration: 2.6
        ))
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        let key = ObjectIdentifier(sharingService)
        let entry = activeServices.removeValue(forKey: key)
        if let temps = entry?.tempURLs { cleanupTemp(temps) }
        let nsErr = error as NSError
        guard nsErr.code != NSUserCancelledError else { return }
        ActivityCenter.shared.show(LiveActivity(
            id: "airdrop.failed",
            kind: .custom,
            symbol: "exclamationmark.triangle.fill",
            title: "AirDrop Cancelled",
            subtitle: nsErr.localizedDescription,
            progress: nil,
            tint: UI.warning,
            duration: 3.0
        ))
    }

    private func cleanupTemp(_ urls: [URL]) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }
}

// MARK: - Shelf Store

/// Files parked on the notch: drag them in, drag them out later, or AirDrop them instantly.
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [URL] = []
    private static let ioQueue = DispatchQueue(label: "KramaIsland.shelfIO", qos: .userInitiated)

    func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        withAnimation(Motion.quick) {
            for url in urls where !items.contains(url) { items.insert(url, at: 0) }
            if items.count > 12 { items.removeLast(items.count - 12) }
        }
        Feedback.tap()
    }

    func remove(_ url: URL) { withAnimation(Motion.quick) { items.removeAll { $0 == url } } }
    func clear() { withAnimation(Motion.quick) { items.removeAll() } }

    func airDrop(_ urls: [URL], temporaryURLs: [URL] = []) {
        AirDropManager.shared.send(urls, temporaryURLs: temporaryURLs)
    }

    /// Accepted UTTypes for AirDrop and Shelf drop targets (files, folders, and browser/app images).
    static let acceptedDropTypes: [UTType] = [.fileURL, .image, .png, .tiff]

    /// Resolves dropped `NSItemProvider`s off the main thread to file URLs (converting in-memory
    /// dragged images into clean PNGs in Caches so even web images AirDrop effortlessly).
    static func resolveDroppedURLs(
        from providers: [NSItemProvider],
        completion: @escaping (_ urls: [URL], _ temporary: [URL]) -> Void
    ) {
        let group = DispatchGroup()
        var urls: [URL] = []
        var temps: [URL] = []
        let lock = NSLock()

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    var rawURL: URL?
                    if let data = item as? Data { rawURL = URL(dataRepresentation: data, relativeTo: nil) }
                    else if let u = item as? URL { rawURL = u }
                    else if let s = item as? String { rawURL = URL(string: s) }
                    if let rawURL {
                        // Resolve macOS Finder file-reference URLs (`file:///.file/id=...`) to real paths.
                        let resolved = (rawURL as NSURL).filePathURL ?? rawURL.standardizedFileURL
                        lock.lock(); urls.append(resolved); lock.unlock()
                    }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                let suggested = provider.suggestedName
                group.enter()
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { group.leave(); return }
                    Self.ioQueue.async {
                        if let fileURL = AirDropManager.writeTempImage(data, suggestedName: suggested) {
                            lock.lock()
                            urls.append(fileURL)
                            temps.append(fileURL)
                            lock.unlock()
                        }
                        group.leave()
                    }
                }
            }
        }
        group.notify(queue: .main) { completion(urls, temps) }
    }
}

// MARK: - Dual Drag-and-Drop Notch Zones (Instant AirDrop | File Shelf)

/// Shown right below the notch the moment you drag a file or image near the top-center of any display:
/// - Left zone: Drop straight onto **AirDrop** to launch macOS AirDrop instantly with zero lag.
/// - Right zone: Drop onto **File Shelf** to park files for dragging out or sharing later.
struct IslandDropZonesView: View {
    @ObservedObject var state: IslandState
    @ObservedObject private var settings = AppSettings.shared
    let displayID: CGDirectDisplayID

    @State private var airDropTargeted = false
    @State private var shelfTargeted = false

    var body: some View {
        HStack(spacing: 10) {
            if settings.airDropEnabled {
                dropZoneTile(
                    symbol: "dot.radiowaves.left.and.right",
                    title: "AirDrop",
                    subtitle: "Share instantly",
                    tint: UI.info,
                    isTargeted: airDropTargeted
                )
                .onDrop(of: ShelfStore.acceptedDropTypes, isTargeted: $airDropTargeted) { providers in
                    handleAirDrop(providers)
                }
                .onChange(of: airDropTargeted) { targeted in
                    if targeted { Feedback.tap() }
                }
            }

            if settings.shelfEnabled {
                dropZoneTile(
                    symbol: "tray.and.arrow.down.fill",
                    title: "File Shelf",
                    subtitle: "Park for later",
                    tint: UI.focus,
                    isTargeted: shelfTargeted
                )
                .onDrop(of: ShelfStore.acceptedDropTypes, isTargeted: $shelfTargeted) { providers in
                    handleShelfDrop(providers)
                }
                .onChange(of: shelfTargeted) { targeted in
                    if targeted { Feedback.tap() }
                }
            }
        }
        .padding(.vertical, 4)
        .onChange(of: airDropTargeted) { _ in syncCombinedTarget() }
        .onChange(of: shelfTargeted) { _ in syncCombinedTarget() }
    }

    private func syncCombinedTarget() {
        if airDropTargeted || shelfTargeted {
            state.setDragTargeted(true, on: displayID)
        }
    }

    private func handleAirDrop(_ providers: [NSItemProvider]) -> Bool {
        state.suppressHover(for: 0.75)
        ShelfStore.resolveDroppedURLs(from: providers) { urls, temps in
            state.setDragTargeted(false, on: displayID)
            state.setHovering(false, on: displayID)
            guard !urls.isEmpty else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                AirDropManager.shared.send(urls, temporaryURLs: temps)
            }
        }
        return true
    }

    private func handleShelfDrop(_ providers: [NSItemProvider]) -> Bool {
        ShelfStore.resolveDroppedURLs(from: providers) { urls, _ in
            state.setDragTargeted(false, on: displayID)
            guard !urls.isEmpty else { return }
            state.shelf.add(urls)
            state.openShade(on: displayID)
        }
        return true
    }

    private func dropZoneTile(
        symbol: String,
        title: String,
        subtitle: String,
        tint: Color,
        isTargeted: Bool
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(tint.opacity(isTargeted ? 0.30 : 0.16))
                    .frame(width: 40, height: 40)
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isTargeted ? .white : tint)
            }
            .scaleEffect(isTargeted ? 1.08 : 1.0)

            VStack(spacing: 1.5) {
                Text(title)
                    .font(UI.title(12.5))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(UI.caption(10))
                    .foregroundStyle(isTargeted ? .white.opacity(0.85) : UI.secondaryText)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 10)
        .background(isTargeted ? tint.opacity(0.22) : UI.cardFill, in: shape)
        .overlay(
            shape.strokeBorder(
                isTargeted ? tint.opacity(0.85) : tint.opacity(0.35),
                style: StrokeStyle(lineWidth: isTargeted ? 1.75 : 1.15, dash: isTargeted ? [] : [5, 4])
            )
        )
        .scaleEffect(isTargeted ? 1.02 : 1.0)
        .animation(Motion.quick, value: isTargeted)
    }
}

// MARK: - Shade AirDrop & File Shelf Card

struct ShelfStrip: View {
    @ObservedObject var shelf: ShelfStore
    @ObservedObject private var settings = AppSettings.shared
    var onCloseShade: () -> Void = {}
    @State private var cardDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(
                symbol: settings.airDropEnabled ? "dot.radiowaves.left.and.right" : "tray.full.fill",
                settings.airDropEnabled ? "AirDrop & Shelf" : "Shelf",
                count: shelf.items.isEmpty ? nil : shelf.items.count
            ) {
                if settings.airDropEnabled {
                    if !shelf.items.isEmpty {
                        PillButton(title: "AirDrop All", symbol: "dot.radiowaves.left.and.right", prominent: true, small: true,
                                   help: "AirDrop all parked files immediately") {
                            let files = shelf.items
                            onCloseShade()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                                shelf.airDrop(files)
                            }
                        }
                    } else {
                        PillButton(title: "Send Files…", symbol: "dot.radiowaves.left.and.right", small: true,
                                   help: "Pick files or folders to AirDrop immediately") {
                            onCloseShade()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                                AirDropManager.shared.pickAndSendFiles()
                            }
                        }
                    }
                    IconButton(symbol: "antenna.radiowaves.left.and.right", size: 22, help: "Open AirDrop in Finder") {
                        onCloseShade()
                        AirDropManager.shared.openAirDropWindow()
                    }
                }
                if !shelf.items.isEmpty {
                    IconButton(symbol: "xmark", size: 22, help: "Clear parked files") { shelf.clear() }
                }
            }

            if shelf.items.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.up.doc.on.clipboard")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(UI.info)
                        .frame(width: 28, height: 28)
                        .background(UI.info.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text(settings.airDropEnabled
                         ? "Drag any file or image to the notch to AirDrop instantly, or drop here to park."
                         : "Drag files onto the notch or drop here to park them for later.")
                        .font(UI.body(10.5))
                        .foregroundStyle(UI.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(shelf.items, id: \.self) { url in
                            ShelfFileTile(
                                url: url,
                                showAirDrop: settings.airDropEnabled,
                                onAirDrop: {
                                    onCloseShade()
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                                        shelf.airDrop([url])
                                    }
                                },
                                onRemove: { shelf.remove(url) }
                            )
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
        .foregroundStyle(.white)
        .islandCard(padding: 12)
        .overlay(
            RoundedRectangle(cornerRadius: UI.cardRadius, style: .continuous)
                .strokeBorder(cardDropTargeted ? UI.info.opacity(0.75) : Color.clear, lineWidth: 1.5)
        )
        .onDrop(of: ShelfStore.acceptedDropTypes, isTargeted: $cardDropTargeted) { providers in
            ShelfStore.resolveDroppedURLs(from: providers) { urls, _ in
                if !urls.isEmpty { shelf.add(urls) }
            }
            return true
        }
        .animation(Motion.quick, value: cardDropTargeted)
    }
}

private struct ShelfFileTile: View {
    let url: URL
    let showAirDrop: Bool
    let onAirDrop: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: AppIconCache.fileIcon(for: url.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 38, height: 38)
                    .padding(.top, 2)

                if hovering {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 15, height: 15)
                            .background(Color.black.opacity(0.75), in: Circle())
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 12, y: -2)
                    .help("Remove from Shelf")
                }
            }
            Text(url.lastPathComponent)
                .font(UI.caption(9.5))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .frame(width: 68)

            if hovering && showAirDrop {
                Button(action: onAirDrop) {
                    HStack(spacing: 3) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 8, weight: .bold))
                        Text("AirDrop")
                            .font(.system(size: 8.5, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .frame(height: 17)
                    .background(UI.info.opacity(0.45), in: Capsule())
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.vertical, 7)
        .frame(width: 80, height: 84)
        .background(hovering ? UI.controlHoverFill : UI.controlFill.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(hovering ? UI.info.opacity(0.45) : Color.white.opacity(0.06), lineWidth: 0.75))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .onDrag { NSItemProvider(object: url as NSURL) }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .help("\(url.lastPathComponent) · Drag out, double-click to open, or AirDrop")
        .contextMenu {
            if showAirDrop {
                Button("AirDrop…", action: onAirDrop)
            }
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button("Remove from Shelf", action: onRemove)
        }
    }
}
