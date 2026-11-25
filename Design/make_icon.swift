// Renders the "Dive in" app icon (1024×1024 PNG).
// Usage: xcrun swift Design/make_icon.swift Reader/Assets.xcassets/AppIcon.appiconset/icon.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let S: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Flip so y grows downward, like design tools.
ctx.translateBy(x: 0, y: S)
ctx.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255, CGFloat(hex & 0xff) / 255, a])!
}

func linear(_ colors: [CGColor], _ locs: [CGFloat], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

// 1. Background: sky-to-deep-sea gradient with a soft glow near the top.
linear([color(0x5CC8F2), color(0x1E7FC4), color(0x0B3B73)], [0, 0.5, 1], from: CGPoint(x: S * 0.3, y: 0), to: CGPoint(x: S * 0.7, y: S))
let glow = CGGradient(colorsSpace: cs, colors: [color(0xFFFFFF, 0.35), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: S * 0.5, y: S * 0.18), startRadius: 0,
                       endCenter: CGPoint(x: S * 0.5, y: S * 0.18), endRadius: S * 0.55, options: [])

// 2. Open book.
let cx = S / 2
let spineTop = CGPoint(x: cx, y: 560)
let spineBottom = CGPoint(x: cx, y: 800)

func page(left: Bool) -> CGPath {
    let d: CGFloat = left ? -1 : 1
    let p = CGMutablePath()
    p.move(to: spineTop)
    // top edge sweeps out and up
    p.addCurve(to: CGPoint(x: cx + d * 330, y: 500),
               control1: CGPoint(x: cx + d * 90, y: 500), control2: CGPoint(x: cx + d * 220, y: 470))
    // outer edge
    p.addLine(to: CGPoint(x: cx + d * 330, y: 740))
    // bottom edge back to spine
    p.addCurve(to: spineBottom,
               control1: CGPoint(x: cx + d * 220, y: 710), control2: CGPoint(x: cx + d * 90, y: 740))
    p.closeSubpath()
    return p
}

// Page stack (thickness) under the top pages
for (i, shade) in [(2, 0x8FC3E8), (1, 0xC6E2F5)] {
    ctx.saveGState()
    ctx.translateBy(x: 0, y: CGFloat(i) * 14)
    for left in [true, false] {
        ctx.addPath(page(left: left))
        ctx.setFillColor(color(UInt32(shade)))
        ctx.fillPath()
    }
    ctx.restoreGState()
}

// Soft shadow under the book
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 40, color: color(0x062447, 0.45))
for left in [true, false] {
    ctx.addPath(page(left: left))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
}
ctx.restoreGState()

// Pages: white with a gentle shade toward the spine
for left in [true, false] {
    ctx.saveGState()
    ctx.addPath(page(left: left))
    ctx.clip()
    let d: CGFloat = left ? -1 : 1
    linear([color(0xD6E6F2), color(0xFFFFFF), color(0xF4F8FB)], [0, 0.35, 1],
           from: CGPoint(x: cx, y: 0), to: CGPoint(x: cx + d * 330, y: 0))
    ctx.restoreGState()
}

// Text lines on the pages
ctx.setLineCap(.round)
ctx.setLineWidth(9)
ctx.setStrokeColor(color(0x9CC3E0, 0.55))
for left in [true, false] {
    let d: CGFloat = left ? -1 : 1
    for i in 0..<2 {
        let y0: CGFloat = 610 + CGFloat(i) * 50
        let p = CGMutablePath()
        p.move(to: CGPoint(x: cx + d * 70, y: y0 + 8))
        p.addQuadCurve(to: CGPoint(x: cx + d * 270, y: y0 - 18), control: CGPoint(x: cx + d * 170, y: y0 - 16))
        ctx.addPath(p)
        ctx.strokePath()
    }
}

// 3. Droplet diving into the gutter.
let drop = CGMutablePath()
let tipY: CGFloat = 230, bodyY: CGFloat = 440, r: CGFloat = 72
drop.move(to: CGPoint(x: cx, y: tipY))
drop.addCurve(to: CGPoint(x: cx + r, y: bodyY),
              control1: CGPoint(x: cx + 18, y: tipY + 90), control2: CGPoint(x: cx + r, y: bodyY - 90))
drop.addArc(center: CGPoint(x: cx, y: bodyY), radius: r, startAngle: 0, endAngle: .pi, clockwise: false)
drop.addCurve(to: CGPoint(x: cx, y: tipY),
              control1: CGPoint(x: cx - r, y: bodyY - 90), control2: CGPoint(x: cx - 18, y: tipY + 90))
drop.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 26, color: color(0x062447, 0.35))
ctx.addPath(drop)
ctx.setFillColor(color(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(drop)
ctx.clip()
linear([color(0xFFFFFF), color(0xBFE6FA)], [0, 1], from: CGPoint(x: cx, y: tipY), to: CGPoint(x: cx, y: bodyY + r))
// highlight
ctx.setFillColor(color(0xFFFFFF, 0.9))
ctx.fillEllipse(in: CGRect(x: cx - 46, y: bodyY - 30, width: 26, height: 40))
ctx.restoreGState()

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out)")
