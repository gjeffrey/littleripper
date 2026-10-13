// Draws the Little Ripper app icon (a glossy optical disc on a deep gradient)
// Usage: swift Scripts/make-icon.swift /path/to/output.png
import AppKit

let size: CGFloat = 1024
let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

// macOS icon-grid rounded rect
let inset: CGFloat = size * 0.098
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius = rect.width * 0.225
let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.addPath(path)
ctx.clip()

// Background: deep indigo-to-midnight gradient
let bgColors = [
    NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.32, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.14, alpha: 1).cgColor,
]
let bgGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: bgColors as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bgGradient,
                       start: CGPoint(x: size / 2, y: size),
                       end: CGPoint(x: size / 2, y: 0), options: [])

// Disc
let center = CGPoint(x: size / 2, y: size / 2)
let discRadius = rect.width * 0.36

// Iridescent sweep (approximate angular gradient with colored wedges)
let wedgeColors: [(CGFloat, CGFloat, CGFloat)] = [
    (1.00, 0.55, 0.65), (0.98, 0.80, 0.50), (0.72, 0.95, 0.60),
    (0.45, 0.85, 0.95), (0.55, 0.60, 1.00), (0.85, 0.55, 0.95),
    (1.00, 0.55, 0.65),
]
let wedgeCount = wedgeColors.count - 1
for i in 0..<wedgeCount {
    let a0 = CGFloat(i) / CGFloat(wedgeCount) * 2 * .pi
    let a1 = CGFloat(i + 1) / CGFloat(wedgeCount) * 2 * .pi + 0.02
    let (r, g, b) = wedgeColors[i]
    let (r2, g2, b2) = wedgeColors[i + 1]
    let steps = 24
    for s in 0..<steps {
        let t = CGFloat(s) / CGFloat(steps)
        let angle0 = a0 + (a1 - a0) * t
        let angle1 = a0 + (a1 - a0) * (t + 1.2 / CGFloat(steps))
        ctx.setFillColor(CGColor(red: r + (r2 - r) * t, green: g + (g2 - g) * t,
                                 blue: b + (b2 - b) * t, alpha: 0.92))
        ctx.move(to: center)
        ctx.addArc(center: center, radius: discRadius, startAngle: angle0,
                   endAngle: angle1, clockwise: false)
        ctx.closePath()
        ctx.fillPath()
    }
}

// Soft radial sheen
let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [NSColor.white.withAlphaComponent(0.55).cgColor,
                                NSColor.white.withAlphaComponent(0.0).cgColor] as CFArray,
                       locations: [0, 1])!
ctx.saveGState()
ctx.addArc(center: center, radius: discRadius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
ctx.clip()
ctx.drawRadialGradient(sheen, startCenter: CGPoint(x: center.x - discRadius * 0.4, y: center.y + discRadius * 0.5),
                       startRadius: 0,
                       endCenter: center, endRadius: discRadius * 1.3, options: [])
ctx.restoreGState()

// Inner ring + hub
ctx.setFillColor(NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.18, alpha: 1).cgColor)
ctx.addArc(center: center, radius: discRadius * 0.30, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
ctx.fillPath()
ctx.setFillColor(NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.26, alpha: 1).cgColor)
ctx.addArc(center: center, radius: discRadius * 0.13, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
ctx.fillPath()

// Rim highlight
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.65).cgColor)
ctx.setLineWidth(size * 0.006)
ctx.addArc(center: center, radius: discRadius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
ctx.strokePath()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath)")
