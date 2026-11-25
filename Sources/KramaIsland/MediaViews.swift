import SwiftUI

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat
    var fallbackIcon: NSImage? = nil

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if let fallbackIcon {
                Image(nsImage: fallbackIcon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(size * 0.1)
                    .background(UI.controlFill)
            } else {
                ZStack {
                    UI.controlFill
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
    }
}

/// The dominant colour of a cover, tuned to read on black: what the Now Playing card is washed
/// with and what the bars in the ear are tinted with. Cached per image.
enum ArtworkPalette {
    private static let cache = NSCache<NSImage, NSColor>()

    static func color(for image: NSImage?) -> Color? {
        guard let image else { return nil }
        if let hit = cache.object(forKey: image) { return Color(nsColor: hit) }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        // Weighted average that favours colourful pixels, so a mostly grey cover with one bright
        // accent picks the accent rather than mud.
        var r = 0.0, g = 0.0, b = 0.0, total = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3]) / 255
            guard a > 0.1 else { continue }
            let pr = Double(pixels[i]) / 255 / a, pg = Double(pixels[i + 1]) / 255 / a, pb = Double(pixels[i + 2]) / 255 / a
            let weight = a * (0.2 + max(pr, pg, pb) - min(pr, pg, pb))
            r += pr * weight; g += pg * weight; b += pb * weight; total += weight
        }
        guard total > 0 else { return nil }

        let base = NSColor(srgbRed: r / total, green: g / total, blue: b / total, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, alpha: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &v, alpha: &alpha)
        let tuned = NSColor(hue: h, saturation: min(1, s * 1.15), brightness: max(0.5, min(0.85, v)), alpha: 1)
        cache.setObject(tuned, forKey: image)
        return Color(nsColor: tuned)
    }
}

/// Four bars that bounce while playing, like the Dynamic Island's.
struct LevelMeter: View {
    let playing: Bool
    var tint: Color = .white

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let phase = t * (2.6 + Double(i) * 0.7) + Double(i) * 1.3
                    let h: CGFloat = playing ? 4 + 10 * CGFloat(0.5 + 0.5 * sin(phase)) : 3
                    Capsule()
                        .fill(tint.opacity(playing ? 1 : 0.5))
                        .frame(width: 3, height: h)
                }
            }
            .frame(height: 14)
        }
    }
}

/// One chip per stream the controller can see (app icon, short name, bars while it plays); tap one
/// to switch the island to it. Chips keep their natural width and wrap onto more rows, so no label
/// is ever clipped.
struct SourcePicker: View {
    let sources: [NowPlaying]
    let current: NowPlaying
    let select: (NowPlaying) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(sources, id: \.sourceKey) { source in
                let selected = source.sourceKey == current.sourceKey
                Button { select(source) } label: {
                    HStack(spacing: 5) {
                        Image(nsImage: source.icon).resizable().frame(width: 14, height: 14)
                        Text(Self.caption(for: source, among: sources))
                            .font(.system(size: 10.5, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize()
                        if source.isPlaying {
                            Image(systemName: "waveform").font(.system(size: 9, weight: .bold))
                        }
                    }
                    .foregroundStyle(selected ? Color.black : .white)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(selected ? Color.white.opacity(0.92) : UI.controlFill, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(source.title.isEmpty ? source.player.name : "\(source.player.name) · \(source.title)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The platform/app name. When the same browser has several streams, the streaming site or
    /// host tells them apart ("YouTube", "SoundCloud", "Chrome · twitch.tv").
    static func caption(for source: NowPlaying, among all: [NowPlaying]) -> String {
        let twins = all.filter { $0.player == source.player }
        if !source.sourceHost.isEmpty, source.platformName != source.player.name {
            return source.platformName
        }
        guard twins.count > 1 else { return source.player.label }
        let hosts = Set(twins.map(\.sourceHost))
        if hosts.count == twins.count, !source.sourceHost.isEmpty {
            return "\(source.player.label) · \(source.sourceHost)"
        }
        guard !source.title.isEmpty else { return source.player.label }
        let short = source.title.count > 18
            ? String(source.title.prefix(17)).trimmingCharacters(in: .whitespaces) + "…"
            : source.title
        return "\(source.player.label) · \(short)"
    }
}

/// Lays children out left to right and starts a new row when the width runs out.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += row + spacing
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: width.isFinite ? width : widest, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += row + spacing
                row = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

/// Now Playing row for the hover readout: artwork, title/artist, transport on top, full-width
/// scrubber below so nothing feels cramped.
struct MediaCard: View {
    let media: NowPlaying
    @ObservedObject var controller: MediaController

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button(action: controller.openPlayer) {
                    ArtworkView(image: media.artwork, size: 46, radius: 11, fallbackIcon: media.icon)
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                }
                .buttonStyle(.plain)
                .help("Open \(media.platformCaption)")

                VStack(alignment: .leading, spacing: 2) {
                    Text(media.title.isEmpty ? media.platformName : media.title)
                        .font(UI.title(13.5))
                        .lineLimit(1)
                    Text(media.subtitle.isEmpty ? media.platformCaption : media.subtitle)
                        .font(UI.body(11.5))
                        .foregroundStyle(UI.secondaryText)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Image(nsImage: media.icon).resizable().frame(width: 11, height: 11)
                        Text(media.platformCaption).font(UI.caption(9.5))
                    }
                    .foregroundStyle(UI.tertiaryText)
                    .padding(.top, 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 4) {
                    TransportButton(symbol: "backward.fill", glyph: 11.5, size: 28) { controller.previous() }
                    TransportButton(symbol: media.isPlaying ? "pause.fill" : "play.fill", glyph: 12.5, size: 32, filled: true) {
                        controller.togglePlayPause()
                    }
                    TransportButton(symbol: "forward.fill", glyph: 11.5, size: 28) { controller.next() }
                }
            }

            ProgressStrip(media: media, onSeek: controller.seek)

            if controller.sources.count > 1 {
                SourcePicker(sources: controller.sources, current: media, select: controller.select)
            }
        }
        .islandCard(padding: 13, tint: ArtworkPalette.color(for: media.artwork))
    }
}

/// A transport glyph. `filled` is the primary action: a white disc with a dark glyph, the way
/// Apple's players draw play / pause.
struct TransportButton: View {
    let symbol: String
    var glyph: CGFloat = 16
    var size: CGFloat = 36
    var filled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: glyph, weight: filled ? .bold : .semibold))
                .offset(x: symbol == "play.fill" ? glyph * 0.07 : 0)   // optical centre of the triangle
                .foregroundStyle(filled ? Color.black : Color.white.opacity(hovering ? 1 : 0.88))
                .frame(width: size, height: size)
                .background(background, in: Circle())
                .scaleEffect(filled && hovering ? 1.05 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }

    private var background: Color {
        if filled { return Color.white.opacity(hovering ? 1 : 0.92) }
        return hovering ? UI.controlFill : Color.clear
    }
}

struct ProgressStrip: View {
    let media: NowPlaying
    let onSeek: (TimeInterval) -> Void
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let elapsed = media.liveElapsed
            let fraction = media.duration > 0 ? min(max(elapsed / media.duration, 0), 1) : 0
            let remaining = max(0, Int((media.duration - elapsed).rounded()))
            HStack(spacing: 8) {
                Text(Self.clock(elapsed))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(UI.track)
                        Capsule().fill(Color.white.opacity(0.88)).frame(width: geo.size.width * fraction)
                    }
                    .frame(height: hovering ? 5 : 3)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                        guard media.duration > 0 else { return }
                        let f = min(max(value.location.x / geo.size.width, 0), 1)
                        onSeek(media.duration * f)
                    })
                }
                .frame(height: 12)
                .onHover { hovering = $0 }
                .animation(Motion.quick, value: hovering)
                Text(media.duration > 0 ? (remaining == 0 ? "0:00" : "-" + Self.clock(TimeInterval(remaining))) : "–:––")
            }
            .font(UI.caption())
            .monospacedDigit()
            .foregroundStyle(UI.secondaryText)
        }
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Shade (notification-centre style)

/// The large Now Playing card for the shade: artwork, title/artist, full-width scrubber, centred
/// transport with a filled play button, and the global output-volume slider. The card is washed
/// with the artwork's colour.
struct ShadeMediaCard: View {
    let media: NowPlaying
    @ObservedObject var controller: MediaController

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Button(action: controller.openPlayer) {
                    ArtworkView(image: media.artwork, size: 64, radius: 14, fallbackIcon: media.icon)
                        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                }
                .buttonStyle(.plain)
                .help("Open \(media.platformCaption)")

                VStack(alignment: .leading, spacing: 3) {
                    Text(media.title.isEmpty ? media.platformName : media.title)
                        .font(UI.title(15))
                        .lineLimit(1)
                    Text(media.subtitle.isEmpty ? media.platformCaption : media.subtitle)
                        .font(UI.body(12))
                        .foregroundStyle(UI.secondaryText)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Image(nsImage: media.icon).resizable().frame(width: 13, height: 13)
                        Text(media.platformCaption).font(UI.caption(10))
                        if media.isPlaying {
                            LevelMeter(playing: true, tint: UI.secondaryText).scaleEffect(0.7)
                        }
                    }
                    .foregroundStyle(UI.secondaryText)
                    .padding(.top, 3)
                }
                Spacer(minLength: 0)
            }

            if controller.sources.count > 1 {
                SourcePicker(sources: controller.sources, current: media, select: controller.select)
            }

            ProgressStrip(media: media, onSeek: controller.seek)

            HStack(spacing: 26) {
                Spacer()
                TransportButton(symbol: "backward.fill", glyph: 17, size: 40) { controller.previous() }
                TransportButton(symbol: media.isPlaying ? "pause.fill" : "play.fill", glyph: 18, size: 46, filled: true) {
                    controller.togglePlayPause()
                }
                TransportButton(symbol: "forward.fill", glyph: 17, size: 40) { controller.next() }
                Spacer()
            }

            VolumeSlider(volume: VolumeController.shared)
        }
        .foregroundStyle(.white)
        .islandCard(tint: ArtworkPalette.color(for: media.artwork))
    }
}
