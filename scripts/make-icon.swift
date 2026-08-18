#!/usr/bin/env swift
// Renders the FineDisplay app icon to a .iconset directory using koboyo hand-drawn icons
// (https://koboyo.com — free for commercial use, no attribution). Usage: make-icon.swift <out.iconset>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let assets = scriptDir.deletingLastPathComponent().appendingPathComponent("Assets/koboyo")

let orange = NSColor(calibratedRed: 1.0, green: 0.46, blue: 0.12, alpha: 1)   // nousworks #ff751f
let ink = NSColor(calibratedRed: 0.11, green: 0.10, blue: 0.12, alpha: 1)
let paper = NSColor(calibratedRed: 0.99, green: 0.97, blue: 0.93, alpha: 1)

func svgImage(_ name: String) -> NSImage {
    let url = assets.appendingPathComponent("\(name).svg")
    guard let img = NSImage(contentsOf: url) else { fatalError("missing \(url.path)") }
    return img
}

/// Draws an SVG (black shapes on transparent) into `rect`, tinted with `color`.
func drawTinted(_ svg: NSImage, in rect: CGRect, color: NSColor, ctx: CGContext) {
    // Render SVG to a bitmap at target size, use it as a mask.
    let scale: CGFloat = 4
    let w = Int(rect.width * scale), h = Int(rect.height * scale)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // Fit preserving aspect ratio.
    let s = svg.size
    let f = min(CGFloat(w) / s.width, CGFloat(h) / s.height)
    let dw = s.width * f, dh = s.height * f
    let dst = NSRect(x: (CGFloat(w) - dw) / 2, y: (CGFloat(h) - dh) / 2, width: dw, height: dh)
    svg.draw(in: dst, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let cg = rep.cgImage else { return }
    ctx.saveGState()
    ctx.clip(to: rect, mask: cg)          // alpha of the rendered SVG becomes the mask
    ctx.setFillColor(color.cgColor)
    ctx.fill(rect)
    ctx.restoreGState()
}

func draw(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { return img }
    let s = size / 1024.0
    ctx.scaleBy(x: s, y: s)

    // macOS icon shape: rounded square, warm paper background with a soft orange glow.
    let bgRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    ctx.setFillColor(paper.cgColor)
    ctx.addPath(bgPath)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [orange.withAlphaComponent(0.55).cgColor, orange.withAlphaComponent(0.0).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 470), startRadius: 40,
                           endCenter: CGPoint(x: 512, y: 470), endRadius: 520, options: [])
    ctx.restoreGState()

    // Screen glass: orange rounded rect roughly where monitor-2's screen sits.
    let monitorRect = CGRect(x: 190, y: 250, width: 644, height: 540)
    let screen = CGRect(x: monitorRect.minX + 74, y: monitorRect.minY + 182, width: monitorRect.width - 148, height: monitorRect.height - 232)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: 22, cornerHeight: 22, transform: nil))
    ctx.clip()
    let sg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [orange.cgColor, NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.30, alpha: 1).cgColor] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(sg, start: CGPoint(x: screen.minX, y: screen.maxY), end: CGPoint(x: screen.maxX, y: screen.minY), options: [])
    // Fine grid = "HiDPI".
    ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.28).cgColor)
    ctx.setLineWidth(3)
    var x = screen.minX + 34
    while x < screen.maxX { ctx.move(to: CGPoint(x: x, y: screen.minY)); ctx.addLine(to: CGPoint(x: x, y: screen.maxY)); x += 34 }
    var y = screen.minY + 34
    while y < screen.maxY { ctx.move(to: CGPoint(x: screen.minX, y: y)); ctx.addLine(to: CGPoint(x: screen.maxX, y: y)); y += 34 }
    ctx.strokePath()
    ctx.restoreGState()

    // koboyo monitor outline in ink.
    drawTinted(svgImage("monitor-2"), in: monitorRect, color: ink, ctx: ctx)

    // koboyo sparkles, top-right, in ink with an orange twin slightly offset for a hand-printed feel.
    let sparkRect = CGRect(x: 640, y: 640, width: 250, height: 250)
    drawTinted(svgImage("sparkles"), in: sparkRect.offsetBy(dx: 6, dy: -6), color: orange, ctx: ctx)
    drawTinted(svgImage("sparkles"), in: sparkRect, color: ink, ctx: ctx)

    img.unlockFocus()
    return img
}

func write(_ image: NSImage, to path: String, pixels: Int) {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
    rep.size = NSSize(width: pixels, height: pixels)
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    write(draw(size: CGFloat(px)), to: "\(outDir)/\(name).png", pixels: px)
}
print("wrote \(sizes.count) icons to \(outDir)")
