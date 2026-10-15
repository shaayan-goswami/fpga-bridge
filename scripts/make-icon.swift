// Draws the FPGA Bridge app icon (1024×1024 PNG): a Liquid Glass chip with a bridge arch on an indigo-to-sky
// gradient. Run through scripts/make-icon.sh, which also builds AppIcon.icns.
import AppKit

let size = 1024.0
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

guard let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.displayP3)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("no context") }

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}
func white(_ a: CGFloat) -> CGColor { CGColor(gray: 1, alpha: a) }
func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.displayP3), colors: colors as CFArray, locations: locations)!
}
func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }

// macOS icon grid: an 824 pt body centred on the 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = rounded(body, 186)

// Drop shadow under the body.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: color(0x000000, 0.35))
ctx.addPath(bodyPath)
ctx.setFillColor(color(0x3B3FD8))
ctx.fillPath()
ctx.restoreGState()

// Body: indigo to sky blue, with soft light pools so the glass has something to refract.
ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
ctx.drawLinearGradient(gradient([color(0x6A4CF5), color(0x3B5BF0), color(0x0FB5E8)], [0, 0.55, 1]),
                       start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
ctx.drawRadialGradient(gradient([color(0xFF7AD9, 0.45), color(0xFF7AD9, 0)]),
                       startCenter: CGPoint(x: 230, y: 260), startRadius: 0, endCenter: CGPoint(x: 230, y: 260), endRadius: 420, options: [])
ctx.drawRadialGradient(gradient([white(0.35), white(0)]),
                       startCenter: CGPoint(x: 300, y: 820), startRadius: 0, endCenter: CGPoint(x: 300, y: 820), endRadius: 520, options: [])
ctx.drawRadialGradient(gradient([color(0x7CF7FF, 0.35), color(0x7CF7FF, 0)]),
                       startCenter: CGPoint(x: 820, y: 300), startRadius: 0, endCenter: CGPoint(x: 820, y: 300), endRadius: 380, options: [])
// Top sheen across the whole body.
ctx.drawLinearGradient(gradient([white(0.22), white(0)]), start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: 560), options: [])
ctx.restoreGState()

// Body rim: a thin bright edge, brighter at the top-left like light catching glass.
ctx.saveGState()
ctx.addPath(bodyPath)
ctx.setLineWidth(5)
ctx.replacePathWithStrokedPath()
ctx.clip()
ctx.drawLinearGradient(gradient([white(0.75), white(0.08), white(0.3)], [0, 0.6, 1]),
                       start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
ctx.restoreGState()

// The chip.
let chip = CGRect(x: 512 - 235, y: 512 - 235, width: 470, height: 470)
let chipPath = rounded(chip, 92)

// Glass pins on all four sides, drawn first so the chip sits on top of them.
for side in 0..<4 {
    for i in 0..<5 {
        let offset = chip.minX + 75 + CGFloat(i) * 80
        let pin: CGRect
        switch side {
        case 0: pin = CGRect(x: offset - 18, y: chip.maxY - 10, width: 36, height: 62)   // top
        case 1: pin = CGRect(x: offset - 18, y: chip.minY - 52, width: 36, height: 62)   // bottom
        case 2: pin = CGRect(x: chip.minX - 52, y: offset - 18, width: 62, height: 36)   // left
        default: pin = CGRect(x: chip.maxX - 10, y: offset - 18, width: 62, height: 36)  // right
        }
        let p = rounded(pin, 14)
        ctx.addPath(p)
        ctx.setFillColor(white(0.30))
        ctx.fillPath()
        ctx.addPath(p)
        ctx.setStrokeColor(white(0.55))
        ctx.setLineWidth(2.5)
        ctx.strokePath()
    }
}

// Chip shadow, then frosted glass fill.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(0x101040, 0.45))
ctx.addPath(chipPath)
ctx.setFillColor(white(0.16))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(chipPath)
ctx.clip()
ctx.drawLinearGradient(gradient([white(0.42), white(0.10), white(0.18)], [0, 0.55, 1]),
                       start: CGPoint(x: chip.midX, y: chip.maxY), end: CGPoint(x: chip.midX, y: chip.minY), options: [])
// Specular highlight: a soft ellipse near the top-left.
ctx.drawRadialGradient(gradient([white(0.45), white(0)]),
                       startCenter: CGPoint(x: chip.minX + 120, y: chip.maxY - 90), startRadius: 0,
                       endCenter: CGPoint(x: chip.minX + 120, y: chip.maxY - 90), endRadius: 230, options: [])
ctx.restoreGState()

// Chip rim.
ctx.saveGState()
ctx.addPath(chipPath)
ctx.setLineWidth(7)
ctx.replacePathWithStrokedPath()
ctx.clip()
ctx.drawLinearGradient(gradient([white(0.95), white(0.15), white(0.55)], [0, 0.55, 1]),
                       start: CGPoint(x: chip.minX, y: chip.maxY), end: CGPoint(x: chip.maxX, y: chip.minY), options: [])
ctx.restoreGState()

// The bridge: an arch over a deck with two towers, glowing.
let deckY = chip.minY + 165
let left = chip.minX + 80, right = chip.maxX - 80
let arch = CGMutablePath()
arch.move(to: CGPoint(x: left, y: deckY))
arch.addQuadCurve(to: CGPoint(x: right, y: deckY), control: CGPoint(x: chip.midX, y: chip.maxY - 40))
let deck = CGMutablePath()
deck.move(to: CGPoint(x: left - 20, y: deckY))
deck.addLine(to: CGPoint(x: right + 20, y: deckY))
let hangers = CGMutablePath()
for i in 1..<8 {
    let t = CGFloat(i) / 8
    let x = left + (right - left) * t
    // Point on the quadratic arch at parameter t.
    let y = (1 - t) * (1 - t) * deckY + 2 * (1 - t) * t * (chip.maxY - 40) + t * t * deckY
    hangers.move(to: CGPoint(x: x, y: deckY))
    hangers.addLine(to: CGPoint(x: x, y: y))
}

func strokeGlowing(_ path: CGPath, width: CGFloat, alpha: CGFloat) {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 28, color: color(0x8FF6FF, 0.95))
    ctx.addPath(path)
    ctx.setStrokeColor(white(alpha))
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()
}
strokeGlowing(hangers, width: 9, alpha: 0.75)
strokeGlowing(arch, width: 24, alpha: 1)
strokeGlowing(deck, width: 22, alpha: 1)

// Two small "signal" dots at the ends of the deck: Mac on one side, build machine on the other.
for x in [left - 20, right + 20] {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 20, color: color(0x8FF6FF, 1))
    ctx.setFillColor(white(1))
    ctx.fillEllipse(in: CGRect(x: x - 20, y: deckY - 20, width: 40, height: 40))
    ctx.restoreGState()
}

guard let image = ctx.makeImage(),
      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { fatalError("encode failed") }
try data.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
