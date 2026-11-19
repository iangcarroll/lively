import AppKit

// Reproducible App Store marketing compositions. App captures are embedded
// without redrawing or changing the interface. Run from the repository root.
let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let locale: String? = {
    guard let index = CommandLine.arguments.firstIndex(of: "--locale") else { return nil }
    guard let value = CommandLine.arguments.dropFirst(index + 1).first, ["ja", "zh-Hant"].contains(value)
    else { fatalError("Expected --locale ja or --locale zh-Hant") }
    return value
}()
let marketing = locale.map { "AppStore/localizations/\($0)/marketing" } ?? "AppStore/marketing"
let captions: [String: String] = try locale.map {
    let url = root.appendingPathComponent("AppStore/localizations/\($0)/captions.json")
    return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
} ?? [:]

func caption(_ english: String) -> String {
    guard locale != nil else { return english }
    if let localized = captions[english] { return localized }
    // Branding, the example language names, counts and page numbers are shared.
    if ["LIVELY", "English", "中文", "日本語"].contains(english)
        || english.allSatisfy({ $0.isNumber || $0 == " " || $0 == "/" }) { return english }
    fatalError("Missing caption for \(english)")
}
let W: CGFloat = 1206, H: CGFloat = 2622
func color(_ hex: String, _ alpha: CGFloat = 1) -> NSColor {
    let v = UInt32(hex, radix:16)!
    return NSColor(srgbRed: CGFloat((v>>16)&255)/255, green: CGFloat((v>>8)&255)/255, blue: CGFloat(v&255)/255, alpha: alpha)
}
let ink = color("24203E"), violet = color("6355DF"), coral = color("E65E4F"), cream = color("F9F5EF")
func rect(_ x: CGFloat,_ y: CGFloat,_ w: CGFloat,_ h: CGFloat,_ c:NSColor,_ r:CGFloat=0) {
    c.setFill(); NSBezierPath(roundedRect:NSRect(x:x,y:y,width:w,height:h),xRadius:r,yRadius:r).fill()
}
func text(_ s:String,_ x:CGFloat,_ y:CGFloat,_ w:CGFloat,_ size:CGFloat,_ c:NSColor=ink,_ weight:String="DemiBold",_ align:NSTextAlignment = .left) {
    let para=NSMutableParagraphStyle(); para.alignment=align; para.lineSpacing = size * 0.015
    let value = caption(s)
    let fontName: String
    switch locale {
    case "ja" where value != s: fontName = weight == "Medium" ? "HiraginoSans-W4" : "HiraginoSans-W7"
    case "zh-Hant" where value != s: fontName = weight == "Medium" ? "PingFangTC-Medium" : "PingFangTC-Semibold"
    default: fontName = "AvenirNext-" + weight
    }
    let font=NSFont(name:fontName,size:size) ?? NSFont.systemFont(ofSize:size,weight:.semibold)
    (value as NSString).draw(in:NSRect(x:x,y:y,width:w,height:900),withAttributes:[.font:font,.foregroundColor:c,.paragraphStyle:para,.kern:-size*0.035])
}
func serif(_ s:String,_ x:CGFloat,_ y:CGFloat,_ w:CGFloat,_ size:CGFloat,_ c:NSColor) {
    let name = locale == "ja" ? "HiraMinProN-W6" : locale == "zh-Hant" ? "Songti-TC-Bold" : "Baskerville-Italic"
    (caption(s) as NSString).draw(in:NSRect(x:x,y:y,width:w,height:500),withAttributes:[.font:NSFont(name:name,size:size) ?? NSFont.systemFont(ofSize:size), .foregroundColor:c,.kern:-size*0.025])
}
func image(_ path:String,_ r:NSRect) {
    let im=NSImage(contentsOf:root.appendingPathComponent(path))!
    im.draw(in:r,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high])
}
func line(_ points:[NSPoint],_ c:NSColor,_ width:CGFloat) {
    let p=NSBezierPath();p.move(to:points[0]);for pt in points.dropFirst(){p.line(to:pt)};p.lineWidth=width;p.lineCapStyle = .round;p.lineJoinStyle = .round;c.setStroke();p.stroke()
}
func wave(_ x:CGFloat,_ y:CGFloat,_ w:CGFloat,_ c:NSColor,_ scale:CGFloat=1) {
    for i in 0..<23 { let t=CGFloat(i)/22;let h=30+100*abs(sin(t*CGFloat.pi*3))*sin(t*CGFloat.pi);rect(x+t*w,y-h*scale/2,13,h*scale,c,7) }
}
func pill(_ s:String,_ x:CGFloat,_ y:CGFloat,_ w:CGFloat,_ bg:NSColor,_ fg:NSColor) {
    rect(x,y,w,64,bg,32);text(s,x+20,y+11,w-40,26,fg,"DemiBold",.center)
}
func phone(_ path:String,_ x:CGFloat,_ y:CGFloat,_ width:CGFloat) {
    // Apple's unmodified iPhone 18 Pro Silver portrait bezel. Its display is
    // exactly 1206 x 2622, inset 72 x 69 in the 1350 x 2760 source PNG.
    let scale=width/1350
    NSGraphicsContext.saveGraphicsState()
    let r=NSRect(x:x+72*scale,y:y+69*scale,width:1206*scale,height:2622*scale)
    NSBezierPath(roundedRect:r,xRadius:170*scale,yRadius:170*scale).addClip()
    image(path,r)
    NSGraphicsContext.restoreGraphicsState()
    image("AppStore/creative/device-frames/iphone-18-pro-silver.png",NSRect(x:x,y:y,width:width,height:2760*scale))
}
func canvas(_ width:Int,_ height:Int,_ output:String,_ draw:()->Void) {
    let cg=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
    let context=NSGraphicsContext(cgContext:cg,flipped:true)
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
    context.cgContext.translateBy(x:0,y:CGFloat(height));context.cgContext.scaleBy(x:1,y:-1)
    NSGraphicsContext.current=NSGraphicsContext(cgContext:context.cgContext,flipped:true)
    context.imageInterpolation = .high
    draw();NSGraphicsContext.restoreGraphicsState()
    let url=root.appendingPathComponent(output);try! fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
    let rep=NSBitmapImageRep(cgImage:cg.makeImage()!)
    try! rep.representation(using:.png,properties:[:])!.write(to:url)
    print(output)
}
// Use the captured screen's aspect ratio so the two Duo displays keep their
// native geometry. These panels show the app directly without a device bezel.
func duoScreen(_ name: String, centeredIn width: CGFloat, top: CGFloat, height: CGFloat) {
    let capture = NSImage(contentsOf: root.appendingPathComponent("AppStore/screenshots/iphone-duo/" + name))!
    let scaledWidth = height * capture.size.width / capture.size.height
    let bounds = NSRect(x: (width - scaledWidth) / 2, y: top, width: scaledWidth, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: bounds, xRadius: 24, yRadius: 24).addClip()
    capture.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                 hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.restoreGraphicsState()
}

canvas(1398, 2034, "\(marketing)/iphone-duo/01-face-to-face.png") {
    rect(0, 0, 1398, 2034, color("211D42"))
    text("Talk face to face.", 75, 50, 1250, 112, .white, "Bold")
    text("One language faces each speaker.", 82, 201, 1230, 47, color("D9D5F3"), "Medium")
    duoScreen("outer-portrait.png", centeredIn: 1398, top: 320, height: 1630)
}

canvas(2853, 2007, "\(marketing)/iphone-duo/02-unfold-the-conversation.png") {
    rect(0, 0, 2853, 2007, cream)
    text("Unfold the conversation.", 112, 38, 2630, 120, ink, "Bold")
    text("Read both languages side by side.", 120, 195, 2610, 52, violet, "Medium")
    duoScreen("inner-landscape.png", centeredIn: 2853, top: 324, height: 1615)
}

if CommandLine.arguments.contains("--duo-only") { exit(0) }

let raw="AppStore/screenshots/raw-2026-11-16/"
let titles=["unused","01-every-word","02-offline-voices","03-your-languages","04-type-translate"]
let orderedTitles=Array(titles.dropFirst())
for i in 1..<5 {
 canvas(Int(W),Int(H),"\(marketing)/iphone-medium/\(titles[i]).png") {
    let dark=i==1;let bg=[cream,color("211D42"),color("F1F0FC"),color("FCEDE7"),color("F1F6F3")][i]
    let fg=dark ? NSColor.white : ink
    rect(0,0,W,H,bg)
    text("LIVELY",80,64,500,30,fg,"Bold")
    text(String(format:"0%d / 04",i),925,70,200,23,dark ? color("B9B2D4"):color("776F83"),"Medium",.right)
    if i==1 {
        text("Every word.\nBoth languages.",80,170,1050,118,.white,"Bold")
        text("Follow the conversation as it happens.",85,510,1010,40,color("CEC9EE"),"Medium")
        wave(100,710,990,color("7468ED"),1.5)
        let transcript = locale.map { "AppStore/localizations/\($0)/transcript.png" } ?? raw+"02-transcript.png"
        phone(transcript,208,820,790)
        pill("LIVE TRANSCRIPT",408,2470,390,color("F3EF85"),ink)
    } else if i==2 {
        text("A voice for\nyour words.",80,170,1040,123,ink,"Bold")
        text("Download once. Speak offline.",85,510,1000,45,violet,"Medium")
        text("54",75,655,400,170,violet,"Bold")
        text("voices",82,845,400,41,ink,"Medium")
        text("8",710,655,400,170,coral,"Bold")
        text("languages",715,845,410,41,ink,"Medium")
        text("Speech and translation models download separately.",85,950,1040,26,color("776F83"),"Medium")
        phone(raw+"03-offline-voices.png",248,1040,710)
        pill("OFFLINE VOICE LIBRARY",338,2510,530,.white,ink)
    } else if i==3 {
        text("Your language.\nTheir language.",80,170,1050,118,ink,"Bold")
        serif("A little closer.",80,482,1050,125,coral)
        text("Choose the pair. Start talking.",85,675,1020,43,ink,"Medium")
        pill("English",80,825,220,.white,violet)
        pill("中文",330,825,205,color("F8CCC1"),coral)
        pill("日本語",565,825,230,color("DCD7FA"),violet)
        phone(raw+"04-languages.png",218,970,770)
    } else {
        text("Type it.\nTranslate it.",80,170,1050,130,ink,"Bold")
        text("Quiet café. Busy street.\nKeep the conversation going.",85,510,1010,45,color("426459"),"Medium")
        pill("TEXT",80,730,220,color("D1E5DA"),color("284F43"))
        pill("PHOTOS",330,730,260,.white,color("284F43"))
        wave(760,765,350,color("65A88D"),0.7)
        phone(raw+"05-typed.png",203,890,800)
    }
 }
}
// Large iPhone placement uses the same marketing design with proportional
// scaling; the app itself remains an unmodified iPhone capture.
for name in orderedTitles {
 canvas(1320,2868,"\(marketing)/iphone-large/\(name).png") {
    rect(0,0,1320,2868,cream)
    image("\(marketing)/iphone-medium/\(name).png",NSRect(x:0,y:0,width:1320,height:2868))
 }
}
canvas(2064,2752,"\(marketing)/ipad-13/01-room-for-conversation.png") {
 rect(0,0,2064,2752,cream)
 text("LIVELY  /  FOR IPAD",100,85,1800,37,violet,"Bold")
 text("More room for\na real conversation.",100,200,1850,166,ink,"Bold")
 text("Two languages, side by side. Always in the moment.",108,650,1850,55,ink,"Medium")
 wave(1480,860,400,coral,1.25)
 let scale:CGFloat=1320/2300
 let frame=NSRect(x:372,y:990,width:1320,height:3000*scale)
 let r=NSRect(x:frame.minX+118*scale,y:frame.minY+124*scale,width:2064*scale,height:2752*scale)
 NSGraphicsContext.saveGraphicsState();NSBezierPath(roundedRect:r,xRadius:40*scale,yRadius:40*scale).addClip()
 image("AppStore/screenshots/ipad-13/01-parallel-transcript.jpg",r)
 NSGraphicsContext.restoreGraphicsState()
 image("AppStore/creative/device-frames/ipad-pro-m5-silver.png",frame)
 pill("SIDE-BY-SIDE TRANSLATION",100,880,680,color("E3DEF9"),violet)
}
if locale == nil {
    canvas(3840,1646,"AppStore/creative/product-page-header.png") {
        rect(0,0,3840,1646,cream)
        image("AppStore/creative/source/conversation-art.png",NSRect(x:0,y:-109.8,width:3840,height:1865.6))
    }
    canvas(1920,1280,"AppStore/creative/search-results.png") {
        rect(0,0,1920,1280,cream)
        image("AppStore/creative/source/conversation-art.png",NSRect(x:-357,y:0,width:2634,height:1280))
    }
}
canvas(1200,652,"\(marketing)/contact-sheet.png") {
 rect(0,0,1200,652,cream)
 for (i,name) in orderedTitles.enumerated() { image("\(marketing)/iphone-medium/\(name).png",NSRect(x:CGFloat(i)*300,y:0,width:300,height:652)) }
}
