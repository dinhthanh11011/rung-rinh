// Renders Resources/AppIcon.icns: a white bell with "ring" waves on an orange squircle.
//   swift scripts/make-icon.swift
import AppKit

func render(_ size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // Squircle background with the standard macOS icon inset.
    let bg = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: bg, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [
        NSColor(calibratedRed: 1.00, green: 0.62, blue: 0.20, alpha: 1),
        NSColor(calibratedRed: 0.95, green: 0.30, blue: 0.25, alpha: 1),
    ])!.draw(in: path, angle: -90)

    // Bell glyph.
    let config = NSImage.SymbolConfiguration(pointSize: 440 * s, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let bell = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let b = bell.size
        bell.draw(in: NSRect(x: (size - b.width) / 2, y: (size - b.height) / 2 - 10 * s, width: b.width, height: b.height))
    }

    // Vibration arcs on both sides.
    for (radius, alpha) in [(300.0, 0.9), (370.0, 0.55)] {
        for (start, end) in [(-30.0, 30.0), (150.0, 210.0)] {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: 512 * s, y: 540 * s), radius: radius * s,
                          startAngle: start, endAngle: end)
            arc.lineWidth = 34 * s
            arc.lineCapStyle = .round
            NSColor.white.withAlphaComponent(alpha).setStroke()
            arc.stroke()
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(CGFloat(base)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(CGFloat(base * 2)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
print("wrote \(out.path)")
