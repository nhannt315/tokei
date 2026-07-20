// Draws the Tokei app icon (gauge on a dark squircle) and emits
// Resources/AppIcon.icns. Regenerate with: swift scripts/generate-icon.swift
// Requires only the CLT (AppKit + iconutil).
import AppKit

let canvas: CGFloat = 1024

func draw(into ctx: CGContext) {
    let s = canvas

    // macOS icon grid: content is a rounded rect inset ~10% on the 1024 canvas.
    let rect = CGRect(x: s * 0.098, y: s * 0.098, width: s * 0.804, height: s * 0.804)
    let path = CGPath(roundedRect: rect, cornerWidth: s * 0.18, cornerHeight: s * 0.18, transform: nil)

    // Background: deep navy → indigo vertical gradient.
    ctx.addPath(path)
    ctx.clip()
    let colors = [
        CGColor(red: 0.10, green: 0.11, blue: 0.20, alpha: 1),
        CGColor(red: 0.22, green: 0.18, blue: 0.38, alpha: 1),
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: s / 2, y: rect.minY),
                           end: CGPoint(x: s / 2, y: rect.maxY),
                           options: [])

    // Gauge: 270° dial, open at the bottom (135°…405° in standard math angles).
    let center = CGPoint(x: s / 2, y: s * 0.47)
    let radius = s * 0.26
    let lineWidth = s * 0.075
    let startAngle = CGFloat.pi * 1.25          // bottom-left
    let fullSweep = CGFloat.pi * 1.5            // 270°
    let usedFraction: CGFloat = 0.30            // purely decorative

    // Track (dim)
    ctx.setLineCap(.round)
    ctx.setLineWidth(lineWidth)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.22))
    ctx.addArc(center: center, radius: radius, startAngle: startAngle,
               endAngle: startAngle - fullSweep, clockwise: true)
    ctx.strokePath()

    // Used portion (Claude orange #D97757)
    ctx.setStrokeColor(CGColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1))
    ctx.addArc(center: center, radius: radius, startAngle: startAngle,
               endAngle: startAngle - fullSweep * usedFraction, clockwise: true)
    ctx.strokePath()

    // Needle pointing at the boundary between used and remaining.
    let needleAngle = startAngle - fullSweep * usedFraction
    let tip = CGPoint(x: center.x + cos(needleAngle) * radius * 0.72,
                      y: center.y + sin(needleAngle) * radius * 0.72)
    ctx.setLineCap(.round)
    ctx.setLineWidth(s * 0.032)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
    ctx.move(to: center)
    ctx.addLine(to: tip)
    ctx.strokePath()

    // Hub
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.95))
    let hub = s * 0.045
    ctx.fillEllipse(in: CGRect(x: center.x - hub, y: center.y - hub, width: hub * 2, height: hub * 2))
}

func renderPNG(size: Int, to url: URL) {
    let ctx = CGContext(data: nil, width: size, height: size,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    draw(into: ctx)
    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    renderPNG(size: base, to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    renderPNG(size: base * 2, to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
try? fm.removeItem(at: iconset)
print("wrote Resources/AppIcon.icns")
