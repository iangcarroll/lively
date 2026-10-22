// Renders the Android launcher icon layers from the same drawing as
// make_icon.swift: the two speech bubbles as an adaptive icon foreground, a
// monochrome layer for themed icons, and the 512×512 Play Store icon. The
// gradient background is a vector drawable (ic_launcher_background.xml).
//
//     swift Tools/icon/make_android_icon.swift android/app/src/main
import AppKit
import UniformTypeIdentifiers

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
    path.append(tailAtLeft ? tail : tail.reversed)
    return path
}

func draw(_ text: String, font: NSFont, color: NSColor, in rect: CGRect) {
    let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    let bounds = string.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin, .usesFontLeading])
    string.draw(at: CGPoint(x: rect.midX - bounds.width / 2, y: rect.midY - bounds.height / 2))
}

func rounded(_ size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
    return NSFont(descriptor: descriptor, size: size) ?? base
}

enum Layer { case foreground, monochrome, store }

/// Draws in make_icon.swift's 1024-point space, scaled by `scale` around the center.
func render(_ layer: Layer, pixels: Int, scale: CGFloat, to path: String) {
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let s = CGFloat(pixels) / 1024
    if layer == .store {
        let gradient = NSGradient(colors: [indigo, NSColor(srgbRed: 0.45, green: 0.3, blue: 0.62, alpha: 1), vermilion])!
        gradient.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels), angle: -45)
    }
    context.translateBy(x: CGFloat(pixels) / 2, y: CGFloat(pixels) / 2)
    context.scaleBy(x: s * scale, y: s * scale)
    context.translateBy(x: -512, y: -512)

    let back = CGRect(x: 150, y: 470, width: 500, height: 360)
    let front = CGRect(x: 374, y: 230, width: 500, height: 360)
    let han = NSFont(name: "PingFangSC-Semibold", size: 230) ?? NSFont.systemFont(ofSize: 230, weight: .semibold)

    if layer == .monochrome {
        // One color, glyphs knocked out; the launcher tints it. The front
        // bubble gets a gap so the two stay apart.
        NSColor.white.setFill()
        bubble(back, tailAtLeft: true).fill()
        context.setBlendMode(.clear)
        draw("A", font: rounded(250, weight: .heavy), color: .white, in: back)
        bubble(front.insetBy(dx: -22, dy: -22), tailAtLeft: false).fill()
        context.setBlendMode(.normal)
        bubble(front, tailAtLeft: false).fill()
        context.setBlendMode(.clear)
        draw("文", font: han, color: .white, in: front.offsetBy(dx: 0, dy: -8))
    } else {
        context.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: NSColor.black.withAlphaComponent(0.22).cgColor)
        NSColor.white.withAlphaComponent(0.95).setFill()
        bubble(back, tailAtLeft: true).fill()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        draw("A", font: rounded(250, weight: .heavy), color: indigo, in: back)
        context.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: NSColor.black.withAlphaComponent(0.25).cgColor)
        NSColor.white.setFill()
        bubble(front, tailAtLeft: false).fill()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        draw("文", font: han, color: vermilion, in: front.offsetBy(dx: 0, dy: -8))
    }
    NSGraphicsContext.restoreGraphicsState()

    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    print("wrote \(path)")
}

let main = CommandLine.arguments.dropFirst().first ?? "android/app/src/main"
// An adaptive icon layer is 108 dp; launchers show the middle 72 dp and
// guarantee only a 66 dp circle, which the bubbles' corners must stay inside.
let layerScale: CGFloat = 0.62
render(.foreground, pixels: 432, scale: layerScale, to: "\(main)/res/drawable-nodpi/ic_launcher_foreground.png")
render(.monochrome, pixels: 432, scale: layerScale, to: "\(main)/res/drawable-nodpi/ic_launcher_monochrome.png")
render(.store, pixels: 512, scale: 1, to: "\(main)/ic_launcher-playstore.png")
