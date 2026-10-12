// Renders the BuildGate app icon (1024px PNG): hammer on a rounded gradient tile.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments[1]
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(red: 0.98, green: 0.55, blue: 0.16, alpha: 1),
                    NSColor(red: 0.86, green: 0.22, blue: 0.20, alpha: 1)])!.draw(in: path, angle: -90)
let cfg = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
if let sym = NSImage(systemSymbolName: "hammer.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let s = sym.size
    sym.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2 - 10, width: s.width, height: s.height))
}
// "2" badge: the build limit
let badge = NSRect(x: 640, y: 150, width: 230, height: 230)
NSColor.white.setFill()
NSBezierPath(ovalIn: badge).fill()
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 170, weight: .heavy),
    .foregroundColor: NSColor(red: 0.86, green: 0.22, blue: 0.20, alpha: 1),
]
let two = NSAttributedString(string: "2", attributes: attrs)
let ts = two.size()
two.draw(at: NSPoint(x: badge.midX - ts.width / 2, y: badge.midY - ts.height / 2))
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
