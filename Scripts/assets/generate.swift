// Draws lain's artwork: the layers of both app icons (Icon Composer documents), the menu-bar and tray glyphs,
// and the README splash. Everything comes from one emblem, an eye made of two wires, defined here once.
//   swift Scripts/assets/generate.swift            # from the repository root; rewrites the files listed below
// Writes:
//   Apps/Host/AppIcon.icon/Assets/{background.png,glow.png,emblem.svg}     the host: the eye bare, on the wire
//   Apps/Client/AppIcon.icon/Assets/{bezel.png,screen.png}                 the client: the eye behind CRT glass
//   Apps/Host/Assets.xcassets/MenuBar{Connected,Idle}.imageset/*.svg       menu-bar templates (20 × 15 pt)
//   rust/dist/icons/lain-{connected,idle}-symbolic.svg                     Linux tray icons (16 × 16)
//   assets/splash.png, assets/splash@2x.png                                README splash (1280 × 640)
// The icon.json and Contents.json files beside them are written by hand.
import AppKit
import CoreText

let space = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ hex: UInt32, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: a)
}
/// A bitmap context with a top-left origin, `scale` pixels per unit.
func makeContext(_ w: Double, _ h: Double, scale: Double = 1) -> CGContext {
    let c = CGContext(data: nil, width: Int(w * scale), height: Int(h * scale), bitsPerComponent: 8, bytesPerRow: 0,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.translateBy(x: 0, y: h * scale); c.scaleBy(x: scale, y: -scale)
    c.interpolationQuality = .high
    return c
}
func write(_ c: CGContext, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}
func write(_ text: String, _ path: String) {
    try! text.write(toFile: path, atomically: true, encoding: .utf8)
    print("wrote \(path)")
}
func linear(_ c: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    c.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
func pill(_ r: CGRect, _ radius: Double) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }

// MARK: The emblem

/// The eye: two wires, each from a node round one side of the iris to just short of the other's node (the same
/// wire turned 180°), a ring and a pupil. Lengths are in the caller's units, about the centre.
struct Emblem {
    var a: Double, h: Double        // a node's distance from the centre; the flat runs' distance above and below
    var k: Double, t: Double        // where a flat run ends (x); how far the tail after it reaches
    var w: Double, node: Double     // stroke weight; node radius
    var ring: Double, ringW: Double // iris ring radius and weight
    var pupil: Double               // 0: no pupil (the glyph for "no iPad connected")

    /// The app icons' proportions, on a 1024 canvas at unit 1.
    static let icon = Emblem(a: 300, h: 170, k: 150, t: 78, w: 34, node: 34, ring: 100, ringW: 34, pupil: 44)
    /// The 16-pixel glyph: the same proportions, with a shorter tail and finer iris so that the gaps stay open.
    static let glyph = Emblem(a: 6.5, h: 3.75, k: 3.0, t: 1.25, w: 1.5, node: 1.25, ring: 2.0, ringW: 0.75, pupil: 0.75)

    /// Filled outlines (no strokes: symbolic-icon recolouring and template images only see fills), one path per
    /// part, each to be filled on its own with the non-zero rule.
    func parts(centre: CGPoint = .zero, unit u: Double = 1) -> [CGPath] {
        var out: [CGPath] = []
        func circle(_ x: Double, _ y: Double, _ r: Double) -> CGPath {
            CGPath(ellipseIn: CGRect(x: centre.x + (x - r) * u, y: centre.y + (y - r) * u, width: 2 * r * u, height: 2 * r * u), transform: nil)
        }
        for s in [1.0, -1.0] {
            let line = CGMutablePath()
            let points = [(-a, 0.0), (-a + h, -h), (k, -h), (k + t, -h + t)]
            line.addLines(between: points.map { CGPoint(x: centre.x + s * $0.0 * u, y: centre.y + s * $0.1 * u) })
            out.append(line.copy(strokingWithWidth: w * u, lineCap: .round, lineJoin: .round, miterLimit: 10))
            out.append(circle(-s * a, 0, node))
        }
        if ring > 0 { out.append(circle(0, 0, ring).copy(strokingWithWidth: ringW * u, lineCap: .butt, lineJoin: .round, miterLimit: 10)) }
        if pupil > 0 { out.append(circle(0, 0, pupil)) }
        return out
    }
}
func fill(_ c: CGContext, _ parts: [CGPath], _ color: CGColor) {
    c.setFillColor(color)
    for p in parts { c.addPath(p); c.fillPath() }
}
/// Fills `parts` with a glow around them: a wide halo, then a tight one.
func glow(_ c: CGContext, _ parts: [CGPath], wide: Double, tight: Double) {
    for (blur, halo, core) in [(wide, rgb(0x35B8FF, 0.9), rgb(0x4FD8FF)), (tight, rgb(0x7FEAFF), rgb(0x7FEBFF))] {
        c.saveGState()
        c.setShadow(offset: .zero, blur: blur, color: halo)
        c.beginTransparencyLayer(auxiliaryInfo: nil); fill(c, parts, core); c.endTransparencyLayer()
        c.restoreGState()
    }
}
func svg(_ parts: [CGPath], width: Double, height: Double, viewBox: CGRect, fill: String) -> String {
    func n(_ v: Double) -> String { String(format: "%.3f", v).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression) }
    var s = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(n(width))\" height=\"\(n(height))\" "
    s += "viewBox=\"\(n(viewBox.minX)) \(n(viewBox.minY)) \(n(viewBox.width)) \(n(viewBox.height))\">\n  <g fill=\"\(fill)\">\n"
    for p in parts {
        var d = ""
        p.applyWithBlock { e in
            let q = e.pointee.points
            switch e.pointee.type {
            case .moveToPoint: d += "M\(n(q[0].x)) \(n(q[0].y))"
            case .addLineToPoint: d += "L\(n(q[0].x)) \(n(q[0].y))"
            case .addQuadCurveToPoint: d += "Q\(n(q[0].x)) \(n(q[0].y)) \(n(q[1].x)) \(n(q[1].y))"
            case .addCurveToPoint: d += "C\(n(q[0].x)) \(n(q[0].y)) \(n(q[1].x)) \(n(q[1].y)) \(n(q[2].x)) \(n(q[2].y))"
            case .closeSubpath: d += "Z"
            @unknown default: break
            }
        }
        s += "    <path d=\"\(d)\"/>\n"
    }
    return s + "  </g>\n</svg>\n"
}

// MARK: Host icon: the eye bare inside the machine, on the wire that runs through it and off both edges

let S = 1024.0
let hostUnit = 1.2, hostCentre = CGPoint(x: S / 2, y: S / 2)
/// The emblem and the live wire through it.
func hostParts() -> [CGPath] {
    let reach = Emblem.icon.a * hostUnit, half = Emblem.icon.w * hostUnit / 2
    return [CGPath(rect: CGRect(x: -8, y: hostCentre.y - half, width: hostCentre.x - reach + 8, height: 2 * half), transform: nil),
            CGPath(rect: CGRect(x: hostCentre.x + reach, y: hostCentre.y - half, width: S - hostCentre.x - reach + 8, height: 2 * half), transform: nil)]
        + Emblem.icon.parts(centre: hostCentre, unit: hostUnit)
}
/// Dim wiring, with the emblem's two-fold symmetry. Points are about the centre, to the canvas edge at ±`edge`.
func wiring(_ c: CGContext, centre: CGPoint, unit u: Double, color: CGColor) {
    let traces: [[(Double, Double)]] = [
        [(-210, -520), (-210, -410), (-150, -350), (190, -350)],
        [(-270, -520), (-270, -400), (-390, -280), (-520, -280)],
        [(-150, -520), (-150, -440), (-110, -400), (330, -400), (400, -330)],
        [(330, -520), (330, -470)],
        [(400, -520), (400, -440), (520, -320)],
        [(-520, -190), (-420, -190)],
    ]
    c.saveGState()
    c.translateBy(x: centre.x, y: centre.y); c.scaleBy(x: u, y: u)
    c.setLineWidth(12); c.setLineCap(.round); c.setLineJoin(.round)
    c.setStrokeColor(color); c.setFillColor(color)
    for turn in [0.0, Double.pi] {
        c.saveGState(); c.rotate(by: turn)
        for t in traces {
            c.addLines(between: t.map { CGPoint(x: $0.0, y: $0.1) }); c.strokePath()
            let end = t.last!
            if abs(end.0) < 510 && abs(end.1) < 510 { c.fillEllipse(in: CGRect(x: end.0 - 16, y: end.1 - 16, width: 32, height: 32)) }
        }
        c.restoreGState()
    }
    c.restoreGState()
}
func navy(_ c: CGContext, centre: CGPoint, radius: Double) {
    let g = CGGradient(colorsSpace: space, colors: [rgb(0x14226E), rgb(0x0A1042), rgb(0x04061C)] as CFArray, locations: [0, 0.55, 1])!
    c.drawRadialGradient(g, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: radius, options: [.drawsAfterEndLocation])
}
func drawHostBackground(_ c: CGContext) {
    navy(c, centre: hostCentre, radius: 720)
    wiring(c, centre: hostCentre, unit: 1, color: rgb(0x2C63D6, 0.75))
}
func drawHostGlow(_ c: CGContext) { glow(c, hostParts(), wide: 110, tight: 28) }

// MARK: Client icon: you look in at the host through a screen, a chunky CRT with bowed glass and a chin

/// A rounded rectangle whose sides bow outward a little, like CRT glass.
func crt(_ r: CGRect, radius: Double, bulge: Double) -> CGPath {
    let p = CGMutablePath()
    let (x0, y0, x1, y1) = (r.minX, r.minY, r.maxX, r.maxY)
    p.move(to: CGPoint(x: x0 + radius, y: y0))
    p.addQuadCurve(to: CGPoint(x: x1 - radius, y: y0), control: CGPoint(x: r.midX, y: y0 - bulge))
    p.addQuadCurve(to: CGPoint(x: x1, y: y0 + radius), control: CGPoint(x: x1, y: y0))
    p.addQuadCurve(to: CGPoint(x: x1, y: y1 - radius), control: CGPoint(x: x1 + bulge, y: r.midY))
    p.addQuadCurve(to: CGPoint(x: x1 - radius, y: y1), control: CGPoint(x: x1, y: y1))
    p.addQuadCurve(to: CGPoint(x: x0 + radius, y: y1), control: CGPoint(x: r.midX, y: y1 + bulge))
    p.addQuadCurve(to: CGPoint(x: x0, y: y1 - radius), control: CGPoint(x: x0, y: y1))
    p.addQuadCurve(to: CGPoint(x: x0, y: y0 + radius), control: CGPoint(x: x0 - bulge, y: r.midY))
    p.addQuadCurve(to: CGPoint(x: x0 + radius, y: y0), control: CGPoint(x: x0, y: y0))
    p.closeSubpath()
    return p
}
let glassRect = CGRect(x: 120, y: 112, width: 784, height: 664)
/// The plastic, for flat renderings; in the icon document it is the fill (icon.json), which follows the appearance.
func drawClientFill(_ c: CGContext) {
    linear(c, [rgb(0xE4E7EE), rgb(0xA9AFBF)], from: .zero, to: CGPoint(x: 0, y: S))
}
/// What sits on the plastic: the recess round the glass, the vent and the power light. Shading only (black and
/// white with alpha), so it works over the light fill and the dark one.
func drawClientBezel(_ c: CGContext) {
    c.saveGState()
    c.addPath(crt(glassRect.insetBy(dx: -22, dy: -22), radius: 120, bulge: 10)); c.clip()
    linear(c, [rgb(0x101420, 0.55), rgb(0xFFFFFF, 0.40)], from: CGPoint(x: 0, y: glassRect.minY - 22), to: CGPoint(x: 0, y: glassRect.maxY + 22))
    c.restoreGState()
    c.setFillColor(rgb(0x101420, 0.45))
    for i in 0..<4 { c.addPath(pill(CGRect(x: 168 + Double(i) * 44, y: 866, width: 20, height: 48), 10)) }
    c.fillPath()
    c.saveGState()
    c.setShadow(offset: .zero, blur: 18, color: rgb(0x4FD8FF, 0.9))
    c.setFillColor(rgb(0x4FD8FF)); c.fillEllipse(in: CGRect(x: 812, y: 868, width: 44, height: 44))
    c.restoreGState()
}
/// The lit glass: navy, the emblem with bloom, scanlines and a sheen.
func drawClientScreen(_ c: CGContext) {
    let centre = CGPoint(x: glassRect.midX, y: glassRect.midY)
    c.saveGState()
    c.addPath(crt(glassRect, radius: 100, bulge: 10)); c.clip()
    let g = CGGradient(colorsSpace: space, colors: [rgb(0x2440C4), rgb(0x16238A), rgb(0x090E45)] as CFArray, locations: [0, 0.6, 1])!
    c.drawRadialGradient(g, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: 560, options: [.drawsAfterEndLocation])
    glow(c, Emblem.icon.parts(centre: centre), wide: 90, tight: 26)
    c.setFillColor(rgb(0x02041C, 0.26))
    var y = glassRect.minY - 12
    while y < glassRect.maxY + 12 { c.fill(CGRect(x: 0, y: y, width: S, height: 4)); y += 10 }
    linear(c, [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)], from: CGPoint(x: 0, y: glassRect.minY), to: CGPoint(x: 0, y: glassRect.midY))
    c.restoreGState()
}

// MARK: Splash: the host's eye on the left, wired to the client's screen on the right

/// The system's icon shape, near enough for a drawing: a superellipse.
func squircle(_ r: CGRect) -> CGPath {
    let p = CGMutablePath(), n = 5.0
    for i in 0...360 {
        let t = Double(i) * .pi / 180
        let pt = CGPoint(x: r.midX + r.width / 2 * copysign(pow(abs(cos(t)), 2 / n), cos(t)),
                         y: r.midY + r.height / 2 * copysign(pow(abs(sin(t)), 2 / n), sin(t)))
        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
    }
    p.closeSubpath()
    return p
}
func text(_ c: CGContext, _ string: String, font: CTFont, color: CGColor, at point: CGPoint, tracking: Double = 0) {
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: color)!, .kern: tracking]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    c.saveGState()
    c.translateBy(x: point.x, y: point.y); c.scaleBy(x: 1, y: -1)   // upright in the top-left context
    c.textPosition = .zero
    CTLineDraw(line, c)
    c.restoreGState()
}
func drawSplash(_ c: CGContext, client: CGImage) {
    let W = 1280.0, H = 640.0
    navy(c, centre: CGPoint(x: 520, y: 300), radius: 900)
    // Dim wiring round the edges, clear of the eye, the name and the screen.
    let traces: [[(Double, Double)]] = [
        [(-10, 70), (150, 70), (200, 120), (330, 120)],
        [(240, -10), (240, 50), (280, 90), (560, 90), (600, 50), (600, -10)],
        [(680, -10), (680, 60), (740, 120)],
        [(760, -10), (760, 40), (1240, 40), (1290, 90)],
        [(-10, 160), (60, 160)],
        [(-10, 440), (90, 440), (130, 480)],
        [(-10, 610), (600, 610), (650, 560), (760, 560)],
        [(600, 430), (700, 430), (740, 470), (740, 510)],
        [(860, 650), (860, 570), (900, 530), (1140, 530), (1180, 570), (1180, 650)],
        [(1290, 300), (1235, 300)],
    ]
    c.saveGState()
    c.setLineWidth(7); c.setLineCap(.round); c.setLineJoin(.round)
    c.setStrokeColor(rgb(0x2C63D6, 0.6)); c.setFillColor(rgb(0x2C63D6, 0.6))
    for t in traces {
        c.addLines(between: t.map { CGPoint(x: $0.0, y: $0.1) }); c.strokePath()
        let end = t.last!
        if (0...W).contains(end.0) && (0...H).contains(end.1) { c.fillEllipse(in: CGRect(x: end.0 - 10, y: end.1 - 10, width: 20, height: 20)) }
    }
    c.restoreGState()
    // The host's eye, the wire off the left edge, and the cable to the screen with some slack in it.
    let eye = CGPoint(x: 350, y: 270), u = 0.62, reach = Emblem.icon.a * u, weight = Emblem.icon.w * u
    let cable = CGMutablePath()
    cable.addLines(between: [CGPoint(x: -20, y: eye.y), CGPoint(x: eye.x - reach, y: eye.y)])
    cable.addLines(between: [CGPoint(x: eye.x + reach, y: eye.y), CGPoint(x: 600, y: eye.y), CGPoint(x: 660, y: eye.y + 60),
                             CGPoint(x: 740, y: eye.y + 60), CGPoint(x: 790, y: eye.y + 10), CGPoint(x: 880, y: eye.y + 10)])
    let live = [cable.copy(strokingWithWidth: weight, lineCap: .butt, lineJoin: .round, miterLimit: 10)] + Emblem.icon.parts(centre: eye, unit: u)
    glow(c, live, wide: 70, tight: 18)
    // The client's screen, standing in front of the cable's end.
    let box = CGRect(x: 830, y: 100, width: 360, height: 360)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: rgb(0x000008, 0.7))
    c.beginTransparencyLayer(auxiliaryInfo: nil)
    c.addPath(squircle(box)); c.clip()
    c.translateBy(x: box.minX, y: box.maxY); c.scaleBy(x: 1, y: -1)
    c.draw(client, in: CGRect(origin: .zero, size: box.size))
    c.endTransparencyLayer()
    c.restoreGState()
    // Name and its expansion.
    c.saveGState()
    c.setShadow(offset: .zero, blur: 26, color: rgb(0x35B8FF, 0.9))
    text(c, "lain", font: CTFontCreateWithName("Menlo-Bold" as CFString, 104, nil), color: rgb(0x7FEBFF), at: CGPoint(x: 160, y: 520), tracking: 6)
    c.restoreGState()
    text(c, "local area interface network", font: CTFontCreateWithName("Menlo-Regular" as CFString, 22, nil), color: rgb(0x7FA8FF),
         at: CGPoint(x: 164, y: 566), tracking: 2)
    // Faint scanlines over everything.
    c.setFillColor(rgb(0x02041C, 0.16))
    var y = 0.0
    while y < H { c.fill(CGRect(x: 0, y: y, width: W, height: 2)); y += 5 }
}

// MARK: Output

let fm = FileManager.default
for dir in ["Apps/Host/AppIcon.icon/Assets", "Apps/Client/AppIcon.icon/Assets", "Apps/Host/Assets.xcassets/MenuBarConnected.imageset",
            "Apps/Host/Assets.xcassets/MenuBarIdle.imageset", "rust/dist/icons", "assets"] {
    try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
}
// Host layers.
var c = makeContext(S, S); drawHostBackground(c); write(c, "Apps/Host/AppIcon.icon/Assets/background.png")
c = makeContext(S, S); drawHostGlow(c); write(c, "Apps/Host/AppIcon.icon/Assets/glow.png")
write(svg(hostParts(), width: S, height: S, viewBox: CGRect(x: 0, y: 0, width: S, height: S), fill: "#8FEEFF"), "Apps/Host/AppIcon.icon/Assets/emblem.svg")
// Client layers.
c = makeContext(S, S); drawClientBezel(c); write(c, "Apps/Client/AppIcon.icon/Assets/bezel.png")
c = makeContext(S, S); drawClientScreen(c); write(c, "Apps/Client/AppIcon.icon/Assets/screen.png")
// Glyphs: connected (with pupil) and idle (without). Linux: 16 × 16. Mac: the same drawing at 20 × 15 points.
var idle = Emblem.glyph; idle.pupil = 0
for (name, emblem) in [("connected", Emblem.glyph), ("idle", idle)] {
    let parts = emblem.parts(centre: CGPoint(x: 8, y: 8))
    write(svg(parts, width: 16, height: 16, viewBox: CGRect(x: 0, y: 0, width: 16, height: 16), fill: "#2e3436"),
          "rust/dist/icons/lain-\(name)-symbolic.svg")
    write(svg(parts, width: 20, height: 15, viewBox: CGRect(x: 0, y: 2, width: 16, height: 12), fill: "#000"),
          "Apps/Host/Assets.xcassets/MenuBar\(name.capitalized).imageset/menubar-\(name).svg")
}
// Splash, with the client icon drawn flat.
let flat = makeContext(S, S); drawClientFill(flat); drawClientBezel(flat); drawClientScreen(flat)
for (scale, name) in [(1.0, "splash.png"), (2.0, "splash@2x.png")] {
    c = makeContext(1280, 640, scale: scale); drawSplash(c, client: flat.makeImage()!); write(c, "assets/\(name)")
}
