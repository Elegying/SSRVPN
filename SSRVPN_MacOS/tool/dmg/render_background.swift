// Rebuild with: swift SSRVPN_MacOS/tool/dmg/render_background.swift <output.png>
// Vector artwork at 2x, with a 720 x 460 point canvas for Retina Finder windows.
import AppKit

let width = 720, height = 460
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * 2,
    pixelsHigh: height * 2, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.current = graphics
let context = graphics.cgContext
context.translateBy(x: 0, y: CGFloat(height))
context.scaleBy(x: 1, y: -1)
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
}
func panel(_ rect: NSRect, radius: CGFloat, fill: NSColor) {
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}
func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat,
          weight: NSFont.Weight = .regular, ink: NSColor, centered: Bool = false) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: ink]
    let string = NSAttributedString(string: value, attributes: attributes)
    let dimensions = string.size()
    context.saveGState()
    context.translateBy(x: centered ? x - dimensions.width / 2 : x,
                        y: y + dimensions.height)
    context.scaleBy(x: 1, y: -1)
    string.draw(at: .zero)
    context.restoreGState()
}
let ink = color(0.10, 0.16, 0.25)
let muted = color(0.40, 0.46, 0.55)
let blue = color(0.13, 0.40, 0.82)
panel(NSRect(x: 0, y: 0, width: width, height: height), radius: 0,
      fill: color(0.96, 0.97, 0.99))
text("SSRVPN", x: 44, y: 30, size: 15, weight: .semibold, ink: blue)
text("安装，只需轻轻一拖", x: 44, y: 60, size: 28, weight: .semibold, ink: ink)
text("将左侧应用拖入右侧 Applications 文件夹", x: 44, y: 134, size: 15, ink: muted)
panel(NSRect(x: 408, y: 24, width: 268, height: 100), radius: 14,
      fill: color(1.0, 0.93, 0.78))
let warning = color(0.47, 0.28, 0.04)
text("覆盖安装提醒", x: 424, y: 34, size: 14, weight: .bold, ink: warning)
text("如本机已打开 SSRVPN 客户端，", x: 424, y: 59, size: 13, ink: warning)
text("覆盖安装前请先退出", x: 424, y: 79, size: 13, ink: warning)
text("SSRVPN 后台。", x: 424, y: 99, size: 13, weight: .semibold, ink: warning)
for x: CGFloat in [70, 410] {
    panel(NSRect(x: x, y: 176, width: 240, height: 166), radius: 22, fill: .white)
}
// Finder draws the two real, draggable icons on top of these cards.
blue.setStroke()
let arrow = NSBezierPath()
arrow.lineWidth = 2.5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 335, y: 240)); arrow.line(to: NSPoint(x: 385, y: 240))
arrow.move(to: NSPoint(x: 376, y: 231)); arrow.line(to: NSPoint(x: 385, y: 240))
arrow.line(to: NSPoint(x: 376, y: 249)); arrow.stroke()
text("拖入以安装", x: 360, y: 266, size: 11, ink: muted, centered: true)
text("安装完成后，从「应用程序」打开 SSRVPN", x: 360, y: 360,
     size: 15, weight: .medium, ink: ink, centered: true)
text("Drag to Applications · Open SSRVPN from Applications", x: 360, y: 389,
     size: 12, ink: muted, centered: true)
text("随后可推出此磁盘映像", x: 360, y: 423, size: 11, ink: muted, centered: true)
NSGraphicsContext.restoreGraphicsState()
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "background.png"
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
