// Uygulama ikonu: SF Symbol kullanılmaz (lisans). Sayfa + açık asma kilit, AppKit ile çizilir.
// Kullanım: swift packaging/make-icon.swift <çıktı.iconset dizini>
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func render(size: CGFloat) -> NSImage {
  let image = NSImage(size: NSSize(width: size, height: size))
  image.lockFocus()
  let s = size
  // Apple ikon ızgarası: 1024 tuval, ~824 gövde, köşe ~%22.37
  let inset = s * 0.098
  let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
  let squircle = NSBezierPath(roundedRect: body, xRadius: body.width * 0.2237, yRadius: body.width * 0.2237)
  let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.22, green: 0.20, blue: 0.36, alpha: 1),
    NSColor(calibratedRed: 0.10, green: 0.09, blue: 0.18, alpha: 1),
  ])!
  gradient.draw(in: squircle, angle: -70)

  // Sayfa (katlı köşe)
  let pw = body.width * 0.46, ph = body.height * 0.60
  let px = body.midX - pw * 0.58, py = body.midY - ph * 0.46
  let fold = pw * 0.26
  let page = NSBezierPath()
  page.move(to: NSPoint(x: px, y: py))
  page.line(to: NSPoint(x: px, y: py + ph))
  page.line(to: NSPoint(x: px + pw - fold, y: py + ph))
  page.line(to: NSPoint(x: px + pw, y: py + ph - fold))
  page.line(to: NSPoint(x: px + pw, y: py))
  page.close()
  NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
  page.fill()
  let foldPath = NSBezierPath()
  foldPath.move(to: NSPoint(x: px + pw - fold, y: py + ph))
  foldPath.line(to: NSPoint(x: px + pw - fold, y: py + ph - fold))
  foldPath.line(to: NSPoint(x: px + pw, y: py + ph - fold))
  foldPath.close()
  NSColor(calibratedWhite: 0.80, alpha: 1).setFill()
  foldPath.fill()
  // Metin çizgileri
  NSColor(calibratedWhite: 0.72, alpha: 1).setFill()
  for i in 0..<4 {
    let ly = py + ph * (0.62 - CGFloat(i) * 0.13)
    let lw = i == 3 ? pw * 0.45 : pw * 0.7
    NSBezierPath(roundedRect: NSRect(x: px + pw * 0.15, y: ly, width: lw, height: ph * 0.045),
                 xRadius: ph * 0.02, yRadius: ph * 0.02).fill()
  }

  // Açık asma kilit (sağ alt)
  let lw = body.width * 0.34, lh = body.height * 0.27
  let lx = body.midX + body.width * 0.06, ly = body.midY - body.height * 0.30
  let bodyRect = NSRect(x: lx, y: ly, width: lw, height: lh)
  let shadow = NSShadow()
  shadow.shadowBlurRadius = s * 0.02
  shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
  shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
  shadow.set()
  NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.20, alpha: 1).setFill()
  NSBezierPath(roundedRect: bodyRect, xRadius: lw * 0.16, yRadius: lw * 0.16).fill()
  NSShadow().set()
  // Kelepçe: açık, sağa kaymış
  let arc = NSBezierPath()
  let r = lw * 0.30
  let cx = lx + lw * 0.68, cy = ly + lh
  arc.appendArc(withCenter: NSPoint(x: cx, y: cy + r * 0.2), radius: r,
                startAngle: 0, endAngle: 180, clockwise: false)
  arc.line(to: NSPoint(x: cx - r, y: cy + r * 0.2 - lh * 0.05))
  arc.lineWidth = lw * 0.13
  arc.lineCapStyle = .round
  NSColor(calibratedWhite: 0.92, alpha: 1).setStroke()
  arc.stroke()
  // Anahtar deliği
  NSColor(calibratedRed: 0.35, green: 0.22, blue: 0.05, alpha: 1).setFill()
  let kr = lw * 0.09
  NSBezierPath(ovalIn: NSRect(x: lx + lw / 2 - kr, y: ly + lh * 0.50 - kr, width: 2 * kr, height: 2 * kr)).fill()
  NSBezierPath(roundedRect: NSRect(x: lx + lw / 2 - kr * 0.4, y: ly + lh * 0.22, width: kr * 0.8, height: lh * 0.3),
               xRadius: kr * 0.3, yRadius: kr * 0.3).fill()
  image.unlockFocus()
  return image
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
                   ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
                   ("512x512", 512), ("512x512@2x", 1024)] {
  let image = render(size: CGFloat(px))
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
  NSGraphicsContext.restoreGraphicsState()
  let png = rep.representation(using: .png, properties: [:])!
  try! png.write(to: outDir.appendingPathComponent("icon_\(name).png"))
}
print("iconset yazıldı: \(outDir.path)")
