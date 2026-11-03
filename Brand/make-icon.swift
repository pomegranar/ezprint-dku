// Draws the app icon: a navy tile, a white page with a folded corner, and a green check badge.
import AppKit

let size: CGFloat = 1024
let navy = NSColor(red: 0x01/255, green: 0x21/255, blue: 0x69/255, alpha: 1)
let navyLight = NSColor(red: 0x0B/255, green: 0x3A/255, blue: 0x96/255, alpha: 1)
let green = NSColor(red: 0x00/255, green: 0x84/255, blue: 0x3D/255, alpha: 1)

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Tile, with a soft drop shadow like system icons.
let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: NSColor(white: 0, alpha: 0.35).cgColor)
navy.setFill(); tile.fill()
ctx.restoreGState()
NSGradient(starting: navyLight, ending: navy)!.draw(in: tile, angle: -90)

// A printer: paper feeding in at the back, the body, and a page coming out the front.
func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
}
func shadowed(_ draw: () -> Void) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 18, color: NSColor(white: 0, alpha: 0.28).cgColor)
    draw()
    ctx.restoreGState()
}

// Paper in the back tray.
NSColor(red: 0.78, green: 0.83, blue: 0.93, alpha: 1).setFill()
rr(340, 600, 344, 220, 26).fill()

// Body.
shadowed { NSColor.white.setFill(); rr(204, 400, 616, 250, 64).fill() }
green.setFill(); NSBezierPath(ovalIn: NSRect(x: 702, y: 512, width: 40, height: 40)).fill()

// Output slot.
navy.withAlphaComponent(0.85).setFill()
rr(262, 452, 500, 26, 13).fill()

// Page coming out.
shadowed { NSColor.white.setFill(); rr(332, 230, 360, 240, 22).fill() }
green.setFill(); rr(380, 392, 150, 28, 14).fill()
for (y, w) in [(330.0, 264.0), (270.0, 190.0)] {
    navy.withAlphaComponent(0.22).setFill()
    rr(380, y, w, 28, 14).fill()
}

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
