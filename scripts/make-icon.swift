// Renders the app icon into an .iconset directory.
// Usage: swift scripts/make-icon.swift build/AppIcon.iconset
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
try? FileManager.default.removeItem(at: out)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.23, yRadius: rect.width * 0.23)
    NSGradient(colors: [
        NSColor(red: 0.10, green: 0.11, blue: 0.20, alpha: 1),
        NSColor(red: 0.20, green: 0.16, blue: 0.42, alpha: 1),
    ])!.draw(in: path, angle: -60)

    // Usage bars.
    let barColors: [NSColor] = [
        NSColor(red: 0.40, green: 0.62, blue: 1.0, alpha: 1),
        NSColor(red: 0.55, green: 0.48, blue: 0.95, alpha: 1),
        NSColor(red: 0.32, green: 0.85, blue: 0.75, alpha: 1),
    ]
    let heights: [CGFloat] = [0.30, 0.48, 0.38]
    let barW = rect.width * 0.14
    let gap = rect.width * 0.07
    let totalW = barW * 3 + gap * 2
    var x = rect.midX - totalW / 2
    for (i, h) in heights.enumerated() {
        let bar = NSRect(x: x, y: rect.minY + rect.height * 0.18, width: barW, height: rect.height * h)
        barColors[i].setFill()
        NSBezierPath(roundedRect: bar, xRadius: barW * 0.3, yRadius: barW * 0.3).fill()
        x += barW + gap
    }

    // Sparkle.
    if let symbol = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: s * 0.22, weight: .bold)) {
        let tinted = NSImage(size: symbol.size, flipped: false) { r in
            symbol.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let size = tinted.size
        tinted.draw(in: NSRect(x: rect.maxX - size.width - rect.width * 0.12,
                               y: rect.maxY - size.height - rect.height * 0.12,
                               width: size.width, height: size.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("Wrote \(out.path)")
