import CoreGraphics
import Foundation

/// "Birleştir" çıktısının doğruluğunu ölçer. `TrimVerification`'la aynı üslupta: kutu/metadata
/// üstverisine değil, gerçekten render edilen piksele bakar — qpdf sayfa içeriğini birebir
/// kopyaladığından, doğru konuma taşınmış bir sayfa kaynağıyla piksel piksel eşleşmelidir.
public enum MergeVerification {
  /// Çıktının sayfa sayısı, girdilerin toplamına eşit mi?
  public static func pageCountMatches(_ url: URL, expected: Int) -> Bool {
    guard let doc = CGPDFDocument(url as CFURL) else { return false }
    return doc.numberOfPages == expected
  }

  /// Bu görüntü-piksel eşleşmesinin toleransı: iki render arasında bu oranın altındaki fark
  /// anti-aliasing/yuvarlama gürültüsü sayılır, üstü gerçek içerik farkı sayılır.
  private static let mismatchThreshold: Double = 0.005

  /// `input`'un `inputPage`. sayfası (1-tabanlı) ile `output`'un `outputPage`. sayfasını aynı
  /// çözünürlükte render edip karşılaştırır. Boyutlar farklıysa ya da sayfalar açılamıyorsa
  /// `false` döner — bu da bir doğrulama başarısızlığıdır.
  public static func pagesMatch(
    input: URL, inputPage: Int, output: URL, outputPage: Int
  ) -> Bool {
    guard
      let inDoc = CGPDFDocument(input as CFURL), let inPage = inDoc.page(at: inputPage),
      let outDoc = CGPDFDocument(output as CFURL), let outPage = outDoc.page(at: outputPage),
      let inBitmap = render(inPage), let outBitmap = render(outPage),
      inBitmap.width == outBitmap.width, inBitmap.height == outBitmap.height
    else { return false }

    let total = inBitmap.width * inBitmap.height
    guard total > 0 else { return true }
    var diff = 0
    for i in 0..<total where abs(Int(inBitmap.data[i]) - Int(outBitmap.data[i])) > 10 { diff += 1 }
    return Double(diff) / Double(total) < mismatchThreshold
  }

  private struct Bitmap { let data: [UInt8]; let width: Int; let height: Int }

  private static func render(_ page: CGPDFPage, dpi: CGFloat = 72) -> Bitmap? {
    let box = page.getBoxRect(.mediaBox)
    guard box.width > 0, box.height > 0 else { return nil }
    let scale = dpi / 72.0
    let width = max(1, Int((box.width * scale).rounded(.up)))
    let height = max(1, Int((box.height * scale).rounded(.up)))
    guard
      let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return nil }
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
    ctx.drawPDFPage(page)
    guard let data = ctx.data else { return nil }
    let bytesPerRow = ctx.bytesPerRow
    let buffer = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
    var out = [UInt8](repeating: 0, count: width * height)
    for row in 0..<height {
      let rowStart = row * bytesPerRow
      for col in 0..<width { out[row * width + col] = buffer[rowStart + col] }
    }
    return Bitmap(data: out, width: width, height: height)
  }
}
