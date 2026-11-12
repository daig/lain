// Draws the background of the Mac host's disk image window (Scripts/release-mac-host.sh): a soft gradient, an
// arrow from the app's spot to the Applications link's, and a caption. The geometry must match
// Scripts/release/dmg-settings.py (window 640 × 400 points; icons centred at x 170 and 470, y 190 from the top).
//   swift Scripts/release/dmg-background.swift <out.png> <scale>   # scale 1 or 2 (Retina)
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let scale = Double(args[2]), scale >= 1 else {
    FileHandle.standardError.write("usage: dmg-background.swift <out.png> <scale>\n".data(using: .utf8)!)
    exit(2)
}
let width = 640.0, height = 400.0
let pixelsWide = Int(width * scale), pixelsHigh = Int(height * scale)

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
rep.size = NSSize(width: width, height: height)   // points: Finder picks the Retina one by its pixel density
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Top-left origin, like Finder's icon positions.
let flip = NSAffineTransform()
flip.translateX(by: 0, yBy: height)
flip.scaleX(by: 1, yBy: -1)
flip.concat()

// Background: a quiet vertical gradient, light enough for Finder's labels in either appearance.
NSGradient(starting: NSColor(srgbRed: 0.975, green: 0.978, blue: 0.985, alpha: 1),
           ending: NSColor(srgbRed: 0.905, green: 0.915, blue: 0.935, alpha: 1))!
    .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 90)

// Arrow between the icons (centred at y 190; 128-point icons span x 106–234 and 406–534).
let arrowColor = NSColor(srgbRed: 0.68, green: 0.70, blue: 0.75, alpha: 1)
let y = 190.0, start = 262.0, tip = 378.0, head = 16.0
let shaft = NSBezierPath()
shaft.move(to: NSPoint(x: start, y: y))
shaft.line(to: NSPoint(x: tip - head * 0.6, y: y))
shaft.lineWidth = 5
shaft.lineCapStyle = .round
arrowColor.setStroke()
shaft.stroke()
let arrowHead = NSBezierPath()
arrowHead.move(to: NSPoint(x: tip, y: y))
arrowHead.line(to: NSPoint(x: tip - head, y: y - head * 0.75))
arrowHead.line(to: NSPoint(x: tip - head, y: y + head * 0.75))
arrowHead.close()
arrowColor.setFill()
arrowHead.fill()

// Caption, drawn upright in the flipped context.
func drawCentred(_ text: String, font: NSFont, color: NSColor, top: Double) {
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let string = NSAttributedString(string: text, attributes: attributes)
    let size = string.size()
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: (width - size.width) / 2, yBy: top + size.height)
    t.scaleX(by: 1, yBy: -1)
    t.concat()
    string.draw(at: .zero)
    NSGraphicsContext.restoreGraphicsState()
}
drawCentred("Drag LainHost to Applications to install it", font: .systemFont(ofSize: 15, weight: .medium),
            color: NSColor(srgbRed: 0.20, green: 0.22, blue: 0.27, alpha: 1), top: 310)
drawCentred("Then open it from Applications: it runs in the menu bar.", font: .systemFont(ofSize: 12),
            color: NSColor(srgbRed: 0.42, green: 0.45, blue: 0.52, alpha: 1), top: 336)

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
do { try png.write(to: URL(fileURLWithPath: args[1])) } catch {
    FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
    exit(1)
}
