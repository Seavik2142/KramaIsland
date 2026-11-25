import AppKit
import CoreGraphics

/// Composites the studio-rendered KramaIsland master artwork (`Resources/AppIcon-artwork.jpg`)
/// into a genuine Apple HIG macOS squircle icon with transparent outer corners, authentic
/// dual-layer elevation shadow, top-lit Liquid Glass rim bevel, and all 10 Retina `.iconset` sizes.

let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repoRoot = scriptDir.deletingLastPathComponent()
let artworkURL = repoRoot.appendingPathComponent("Resources/AppIcon-artwork.jpg")

guard let sourceImage = NSImage(contentsOf: artworkURL),
      let sourceCG = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("error: failed to load master artwork at \(artworkURL.path)\n", stderr)
    exit(1)
}

// Crop the 1024x1024 artwork tightly inside its dark canvas (76..947) anchored at the top bezel
// (y=78) so the Dynamic Island notch sits 100% flush with the top edge of the squircle and the
// Liquid Glass "K" monogram sits optically centered with bold legibility down to 16x16.
let cropRect = CGRect(x: 144, y: 78, width: 736, height: 736)
guard let croppedCG = sourceCG.cropping(to: cropRect) else {
    fputs("error: failed to crop artwork\n", stderr)
    exit(1)
}

/// Official macOS HIG app icon silhouette: flat straight edges with crisp 22.37% corner radius
/// matching Apple's official macOS icon grid (`184.3 pt` corner radius on an `824 pt` body).
func makeSquirclePath(in rect: CGRect, cornerRatio: CGFloat = 0.2237) -> CGPath {
    let r = min(rect.width, rect.height) * cornerRatio
    return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}

func draw(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(px)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    // Official macOS HIG app icon safe grid: 824x824 centered inside 1024x1024 (inset = 100/1024).
    let inset = s * (100.0 / 1024.0)
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let squircle = makeSquirclePath(in: body)

    // Dual-layer authentic macOS Dock drop shadow (ambient + tight contact shadow).
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.016),
        blur: s * 0.038,
        color: NSColor.black.withAlphaComponent(0.42).cgColor
    )
    ctx.setFillColor(NSColor(calibratedRed: 0.03, green: 0.05, blue: 0.10, alpha: 1).cgColor)
    ctx.addPath(squircle)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.005),
        blur: s * 0.012,
        color: NSColor.black.withAlphaComponent(0.28).cgColor
    )
    ctx.setFillColor(NSColor(calibratedRed: 0.03, green: 0.05, blue: 0.10, alpha: 1).cgColor)
    ctx.addPath(squircle)
    ctx.fillPath()
    ctx.restoreGState()

    // Clip to continuous squircle and render high-res artwork.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    ctx.draw(croppedCG, in: body)

    // Subtle machined glass specular rim around the inside edge (brighter on top, soft at bottom).
    let rimInset = max(0.5, s * 0.0025)
    let innerSquircle = makeSquirclePath(in: body.insetBy(dx: rimInset, dy: rimInset))
    ctx.saveGState()
    ctx.addPath(innerSquircle)
    ctx.setLineWidth(max(1.0, s * 0.0055))
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let cs = CGColorSpaceCreateDeviceRGB()
    let rimColors = [
        NSColor(calibratedRed: 0.72, green: 0.90, blue: 1.00, alpha: 0.34).cgColor,
        NSColor.white.withAlphaComponent(0.14).cgColor,
        NSColor.white.withAlphaComponent(0.05).cgColor,
    ] as CFArray
    if let rimGrad = CGGradient(colorsSpace: cs, colors: rimColors, locations: [0.0, 0.35, 1.0]) {
        ctx.drawLinearGradient(
            rimGrad,
            start: CGPoint(x: body.midX, y: body.maxY),
            end: CGPoint(x: body.midX, y: body.minY),
            options: []
        )
    }
    ctx.restoreGState()

    ctx.restoreGState() // end squircle clip

    // Crisp outer hairline so the icon defines cleanly on both Light and Dark macOS themes.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.32).cgColor)
    ctx.setLineWidth(max(0.75, s * 0.002))
    ctx.strokePath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (name, px) in [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
] {
    let rep = draw(px)
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
print("iconset written to \(out)")
