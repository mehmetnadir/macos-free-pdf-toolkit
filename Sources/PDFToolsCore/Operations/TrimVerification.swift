import CoreGraphics
import Foundation

/// "Kesim Payını At" çıktısının kesim payını GERÇEKTEN atıp atmadığını ölçer. Kutu üstverisine
/// (MediaBox/CropBox) güvenmez — motorlar (özellikle gs, bkz. GhostscriptEngine.swift) kutuyu
/// küçültüp içeriği kırpmadan bırakabilir. Yöntem: çıktı sayfasının KENDİ bildirdiği kutusunu her
/// yönde `marginPoints` genişletip render et; eski sınırın DIŞINDA kalan banttaki beyaz olmayan
/// piksel oranına bak. Bu yöntem `.claude/docs/yol-haritasi-2026-09.md`'de gerçek bir matbaa
/// dosyasıyla (300 dpi / 30pt bant) doğrulandı; burada operasyonel maliyeti düşük tutmak için
/// 150 dpi / 8,5pt (≈ 3 mm — ölçülen gerçek kesim payı) kullanılır.
public enum TrimVerification {
  public enum Verdict: Sendable, Equatable {
    /// Bant tamamen (< %2) temiz — kesim payı gerçekten silinmiş.
    case clean
    /// Bantta iz var (%2–%10) ama küçük — çıktı korunur, kullanıcıya oran gösterilir.
    case partial
    /// Bant büyük ölçüde dolu (> %10) — kesim payı fiilen silinmemiş, çıktı reddedilir.
    case failed
  }

  public struct Result: Sendable, Equatable {
    public let residuePercent: Double
    public let verdict: Verdict
  }

  /// İnceleme bandı genişliği (punto). Gerçek matbaa dosyasında ölçülen kesim payıyla eşleşir.
  public static let marginPoints: CGFloat = 8.5
  public static let renderDPI: CGFloat = 150
  /// Bu luma değerinin (0–255, gri tonlama) altı "mürekkep var" sayılır; 255 saf beyaz.
  private static let inkLumaThreshold: UInt8 = 245
  private static let cleanThreshold: Double = 2.0
  private static let failedThreshold: Double = 10.0

  /// `url`'deki PDF'in ilk sayfasını inceler. Sayfa açılamıyorsa ya da kutusu dejenereyse
  /// güvenli tarafta kalıp `.failed` döner (kanıtsız "temiz" raporlamamak için).
  public static func verify(_ url: URL) -> Result {
    guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1) else {
      return Result(residuePercent: 100, verdict: .failed)
    }
    let originalBox = page.getBoxRect(.mediaBox)
    guard originalBox.width > 0, originalBox.height > 0 else {
      return Result(residuePercent: 100, verdict: .failed)
    }
    let expanded = originalBox.insetBy(dx: -marginPoints, dy: -marginPoints)
    let scale = renderDPI / 72.0
    let pxWidth = max(1, Int((expanded.width * scale).rounded(.up)))
    let pxHeight = max(1, Int((expanded.height * scale).rounded(.up)))

    guard
      let ctx = CGContext(
        data: nil, width: pxWidth, height: pxHeight, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else {
      return Result(residuePercent: 100, verdict: .failed)
    }
    // Beyaz zemin: sayfa dışına taşan hiçbir şey yoksa bant tamamen beyaz kalır.
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: pxWidth, height: pxHeight))
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -expanded.origin.x, y: -expanded.origin.y)
    // Not: CGContext.drawPDFPage kutuya göre KIRPMAZ (Apple dokümantasyonu) — tam da bunu
    // istiyoruz: sayfanın bildirdiği kutunun dışında kalan gerçek içeriği görünür kılmak.
    ctx.drawPDFPage(page)

    guard let data = ctx.data else {
      return Result(residuePercent: 100, verdict: .failed)
    }
    let bytesPerRow = ctx.bytesPerRow
    let buffer = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * pxHeight)

    var bandPixels = 0
    var inkPixels = 0
    for row in 0..<pxHeight {
      // CGContext(data: nil, ...) ile oluşturulan gri tonlamalı bitmap'in ham arabelleği satır 0
      // = görüntünün ÜSTÜ (en yüksek kullanıcı-uzayı y'si) ile başlıyor — ekstra flip UYGULANMADI,
      // bu proje içinde ölçülüp doğrulandı (bkz. oturum notları / scratchpad ölçümü, 2026-09-07).
      let userY = expanded.maxY - (Double(row) + 0.5) / Double(scale)
      let rowStart = row * bytesPerRow
      for col in 0..<pxWidth {
        let userX = expanded.origin.x + (Double(col) + 0.5) / Double(scale)
        guard !originalBox.contains(CGPoint(x: userX, y: userY)) else { continue }
        bandPixels += 1
        if buffer[rowStart + col] < inkLumaThreshold {
          inkPixels += 1
        }
      }
    }

    let percent = bandPixels == 0 ? 0 : Double(inkPixels) / Double(bandPixels) * 100
    let verdict: Verdict
    if percent < cleanThreshold {
      verdict = .clean
    } else if percent <= failedThreshold {
      verdict = .partial
    } else {
      verdict = .failed
    }
    return Result(residuePercent: percent, verdict: verdict)
  }
}
