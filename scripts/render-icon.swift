// Renders a placeholder 1024 px app icon (rounded square with a waveform) with CoreGraphics. Usage: swift render-icon.swift out.png
import AppKit
import Foundation

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let rect = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: 60, dy: 60)
let path = CGPath(roundedRect: rect, cornerWidth: 220, cornerHeight: 220, transform: nil)
ctx.addPath(path)
ctx.clip()
let colors = [CGColor(red: 0.16, green: 0.33, blue: 0.85, alpha: 1), CGColor(red: 0.45, green: 0.2, blue: 0.75, alpha: 1)] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
ctx.setLineWidth(58)
ctx.setLineCap(.round)
let heights: [CGFloat] = [0.18, 0.42, 0.72, 0.95, 0.6, 0.82, 0.38, 0.2]
let spacing = CGFloat(size) * 0.085
let startX = CGFloat(size) / 2 - spacing * CGFloat(heights.count - 1) / 2
for (i, h) in heights.enumerated() {
    let x = startX + spacing * CGFloat(i)
    let half = CGFloat(size) * 0.3 * h
    ctx.move(to: CGPoint(x: x, y: CGFloat(size) / 2 - half))
    ctx.addLine(to: CGPoint(x: x, y: CGFloat(size) / 2 + half))
}
ctx.strokePath()
image.unlockFocus()
let tiff = image.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
print("✓ \(out)")
