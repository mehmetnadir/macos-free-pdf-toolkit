import CoreGraphics
import Foundation

/// "Filigran Ekle" çıktısının GERÇEKTEN beklenen bölgede filigran bıraktığını ölçer — kendi çizim
/// kodumuza (`WatermarkAddOperation`) güvenmez. Yöntem `TrimVerification`/`CompressVerification`
/// ile AYNI üslup: sayfayı render edip beklenen bölgedeki (konum: merkez/üst/alt) mürekkep oranını
/// KAYNAK ve ÇIKTI için AYRI AYRI ölçer, ÇIKTIDA GERÇEKTEN artış (fark eşiğin üstünde) olduğunu
/// doğrular — kutu/metin üstverisine değil render edilen piksele bakar.
public enum WatermarkVerification {
  public static let renderDPI: CGFloat = 150
  /// Bu luma değerinin (0-255, gri tonlama) altı "mürekkep var" sayılır — `CompressVerification`'ın
  /// "raster" kademesi için kullandığı eşikle AYNI (bkz. o dosyadaki gerekçe).
  private static let inkLumaThreshold: UInt8 = 250
  /// Çıktı−kaynak mürekkep yüzdesi farkının bu değerin ÜSTÜNDE olması "filigran gerçekten eklendi"
  /// kanıtıdır. Ölçüldü (bu proje içinde, `Tur7Tests` fixture'ıyla): varsayılan seçeneklerde
  /// (opaklık %15, gri, 36pt) bile bölgesel fark bu eşiğin belirgin üstünde çıkıyor; eşik düşük
  /// tutuldu ki en zayıf ayar (opaklık %15) da güvenle yakalansın.
  public static let minDeltaPercent: Double = 0.3

  /// `position`'a göre incelenecek NORMALİZE (0...1, PDF orijini SOL-ALT) bölge.
  /// `WatermarkAddOperation` ile aynı üç konumu kapsar; "center" çapraz metnin sayfa ortasından
  /// GEÇTİĞİ geniş bir bölgedir.
  public static func region(for position: String) -> CGRect {
    switch position {
    case "header": return CGRect(x: 0.05, y: 0.8, width: 0.9, height: 0.2)
    case "footer": return CGRect(x: 0.05, y: 0.0, width: 0.9, height: 0.2)
    default: return CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.6)  // "center" (çapraz)
    }
  }

  /// `url`'in `pageIndex` (1-tabanlı) sayfasını render edip `region` içindeki mürekkep yüzdesini
  /// döner. Sayfa/döküman açılamazsa ya da kutusu dejenereyse `nil`.
  public static func inkPercent(pdfAt url: URL, pageIndex: Int, region: CGRect) -> Double? {
    guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: pageIndex) else {
      return nil
    }
    let box = page.getBoxRect(.mediaBox)
    guard box.width > 0, box.height > 0 else { return nil }
    let scale = renderDPI / 72.0
    let pxWidth = max(1, Int((box.width * scale).rounded()))
    let pxHeight = max(1, Int((box.height * scale).rounded()))
    guard
      let ctx = CGContext(
        data: nil, width: pxWidth, height: pxHeight, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return nil }
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: pxWidth, height: pxHeight))
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
    ctx.drawPDFPage(page)
    guard let data = ctx.data else { return nil }
    let bytesPerRow = ctx.bytesPerRow
    let buffer = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * pxHeight)

    // Satır 0 = görüntünün ÜSTÜ (bkz. `TrimVerification` aynı ölçülmüş not) — normalize bölgenin
    // ÜST sınırı (region.maxY, daha büyük y) daha KÜÇÜK satır indeksine karşılık gelir.
    let rowTop = max(0, Int(((1 - region.maxY) * CGFloat(pxHeight)).rounded()))
    let rowBottom = min(pxHeight, Int(((1 - region.minY) * CGFloat(pxHeight)).rounded()))
    let colLeft = max(0, Int((region.minX * CGFloat(pxWidth)).rounded()))
    let colRight = min(pxWidth, Int((region.maxX * CGFloat(pxWidth)).rounded()))
    guard rowTop < rowBottom, colLeft < colRight else { return 0 }

    var total = 0
    var ink = 0
    for row in rowTop..<rowBottom {
      let rowStart = row * bytesPerRow
      for col in colLeft..<colRight {
        total += 1
        if buffer[rowStart + col] < inkLumaThreshold { ink += 1 }
      }
    }
    return total == 0 ? 0 : Double(ink) / Double(total) * 100
  }

  /// Kaynak ile çıktının AYNI bölgesindeki mürekkep oranını kıyaslar (çıktı − kaynak). Biri
  /// açılamazsa `nil` — çağıran bunu "ölçülemedi" olarak ayrı ele alır, sessizce başarılı SAYMAZ.
  public static func delta(
    sourceURL: URL, outputURL: URL, pageIndex: Int, position: String
  ) -> Double? {
    let r = region(for: position)
    guard let sourcePercent = inkPercent(pdfAt: sourceURL, pageIndex: pageIndex, region: r),
      let outputPercent = inkPercent(pdfAt: outputURL, pageIndex: pageIndex, region: r)
    else { return nil }
    return outputPercent - sourcePercent
  }
}
