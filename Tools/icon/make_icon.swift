// Renders Lively's 1024×1024 app icon: two overlapping speech bubbles, "A" in
// the English indigo and "文" in the Chinese vermilion, on a gradient between
// the two.
//
//     swift Tools/icon/make_icon.swift Lively/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import AppKit
import UniformTypeIdentifiers

let size: CGFloat = 1024
let indigo = NSColor(srgbRed: 61 / 255, green: 79 / 255, blue: 214 / 255, alpha: 1)
let vermilion = NSColor(srgbRed: 214 / 255, green: 69 / 255, blue: 47 / 255, alpha: 1)

func bubble(_ rect: CGRect, tailAtLeft: Bool) -> NSBezierPath {
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.height * 0.32, yRadius: rect.height * 0.32)
    let tail = NSBezierPath()
    let baseY = rect.minY + 6
    if tailAtLeft {
        tail.move(to: CGPoint(x: rect.minX + rect.width * 0.18, y: baseY))
        tail.line(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.minY - rect.height * 0.2))
        tail.line(to: CGPoint(x: rect.minX + rect.width * 0.38, y: baseY))
    } else {
        tail.move(to: CGPoint(x: rect.maxX - rect.width * 0.18, y: baseY))
        tail.line(to: CGPoint(x: rect.maxX - rect.width * 0.08, y: rect.minY - rect.height * 0.2))
        tail.line(to: CGPoint(x: rect.maxX - rect.width * 0.38, y: baseY))
    }
    tail.close()
    // Wind the tail the same way as the bubble so the overlap fills instead of cancelling.
    path.append(tailAtLeft ? tail : tail.reversed)
    return path
}

func draw(_ text: String, font: NSFont, color: NSColor, in rect: CGRect) {
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let string = NSAttributedString(string: text, attributes: attributes)
    let bounds = string.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin, .usesFontLeading])
    string.draw(at: CGPoint(x: rect.midX - bounds.width / 2, y: rect.midY - bounds.height / 2))
}

func rounded(_ size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
    return NSFont(descriptor: descriptor, size: size) ?? base
}

// Opaque 1024×1024 sRGB bitmap (App Store icons can't have alpha).
let context = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

// Full-bleed background; iOS applies the corner mask.
let gradient = NSGradient(colors: [indigo, NSColor(srgbRed: 0.45, green: 0.3, blue: 0.62, alpha: 1), vermilion])!
gradient.draw(in: CGRect(x: 0, y: 0, width: size, height: size), angle: -45)

// Back bubble (English), upper left.
let back = CGRect(x: 150, y: 470, width: 500, height: 360)
context.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: NSColor.black.withAlphaComponent(0.22).cgColor)
NSColor.white.withAlphaComponent(0.95).setFill()
bubble(back, tailAtLeft: true).fill()
context.setShadow(offset: .zero, blur: 0, color: nil)
draw("A", font: rounded(250, weight: .heavy), color: indigo, in: back)

// Front bubble (Chinese), lower right, overlapping.
let front = CGRect(x: 374, y: 230, width: 500, height: 360)
context.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: NSColor.black.withAlphaComponent(0.25).cgColor)
NSColor.white.setFill()
bubble(front, tailAtLeft: false).fill()
context.setShadow(offset: .zero, blur: 0, color: nil)
let han = NSFont(name: "PingFangSC-Semibold", size: 230) ?? NSFont.systemFont(ofSize: 230, weight: .semibold)
draw("文", font: han, color: vermilion, in: front.offsetBy(dx: 0, dy: -8))

NSGraphicsContext.restoreGraphicsState()
let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
CGImageDestinationFinalize(destination)
print("wrote \(out)")
