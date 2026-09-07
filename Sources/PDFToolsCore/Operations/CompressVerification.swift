import CoreGraphics
import Foundation

/// "Sıkıştır" çıktısının doğruluğunu ölçer: motora güvenmez, çıktıyı bizzat açıp ölçer
/// (`TrimVerification`/`MergeVerification`'la aynı üslup).
public enum CompressVerification {
  public enum SizeVerdict: Sendable, Equatable {
    /// Çıktı kaynaktan küçük.
    case smaller
    /// Çıktı kaynaktan küçük DEĞİL (bazı zaten sıkıştırılmış PDF'lerde yeniden paketleme
    /// büyütebilir) — çağıran bunu SESSİZCE "başarılı" saymaz, `note` ile kullanıcıya bildirir.
    case notSmaller
  }

  public struct SizeResult: Sendable, Equatable {
    public let inputBytes: Int64
    public let outputBytes: Int64
    public let verdict: SizeVerdict
  }

  /// İki dosyanın boyutunu karşılaştırır. Okunamayan dosya 0 bayt sayılır (PDFFileInfo.inspect
  /// ile aynı desen: `resourceValues(forKeys:).fileSize`).
  public static func compareSize(input: URL, output: URL) -> SizeResult {
    let inBytes = fileSize(input)
    let outBytes = fileSize(output)
    return SizeResult(
      inputBytes: inBytes, outputBytes: outBytes,
      verdict: outBytes < inBytes ? .smaller : .notSmaller)
  }

  private static func fileSize(_ url: URL) -> Int64 {
    (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
  }

  /// Çıktı geçerli bir PDF mi ve sayfa sayısı beklenenle uyuşuyor mu?
  public static func pageCountMatches(_ url: URL, expected: Int) -> Bool {
    guard let doc = CGPDFDocument(url as CFURL) else { return false }
    return doc.numberOfPages == expected
  }

  /// `page`'in KENDİ (üst düzey) içerik akışında gerçek bir metin gösterme operatörü
  /// (`Tj`/`TJ`/`'`/`"`) var mı? Form XObject'lere (`Do` ile çağrılan iç içe akışlar) İNMEZ —
  /// bu turun kapsamı dışında bırakıldı, tipik tek-akışlı sayfalar için yeterli.
  ///
  /// NEDEN basit "sayfayı render edip boş değil mi" kontrolü YETERLİ DEĞİL: "raster" kademesi de
  /// sayfaya görüntüyü "mürekkep" olarak basar — non-white piksel oranı METİN ile GÖRÜNTÜ
  /// arasında ayrım YAPAMAZ, ikisi de "dolu" görünür. Operatör taraması gerçek metin gösterme
  /// komutunu arar; bu proje içinde ölçülüp doğrulandı (2026-09-08): CoreText ile yazılan bir
  /// sayfa hem qpdf `--recompress-flate` hem de `gs -dPDFSETTINGS=/ebook` sonrası `true` döndü,
  /// aynı sayfanın rasterize edilmiş hâli (görüntü olarak çizilmiş) `false` döndü.
  public static func containsTextOperator(_ page: CGPDFPage) -> Bool {
    let stream = CGPDFContentStreamCreateWithPage(page)
    defer { CGPDFContentStreamRelease(stream) }
    guard let table = CGPDFOperatorTableCreate() else { return false }
    defer { CGPDFOperatorTableRelease(table) }
    let box = TextFoundBox()
    let callback: CGPDFOperatorCallback = { _, info in
      guard let info else { return }
      Unmanaged<TextFoundBox>.fromOpaque(info).takeUnretainedValue().found = true
    }
    for op in ["Tj", "TJ", "'", "\""] {
      CGPDFOperatorTableSetCallback(table, op, callback)
    }
    let infoPointer = Unmanaged.passUnretained(box).toOpaque()
    let scanner = CGPDFScannerCreate(stream, table, infoPointer)
    defer { CGPDFScannerRelease(scanner) }
    CGPDFScannerScan(scanner)
    return box.found
  }

  /// C callback'in ham işaretçi parametresi için taşıyıcı — `CGPDFScanner` Swift closure'ı
  /// doğrudan yakalayamadığından (`@convention(c)`), durumu `Unmanaged` ile bir sınıf üzerinden taşır.
  private final class TextFoundBox { var found = false }

  /// "raster" kademesi için: sayfanın beyaz-olmayan piksel oranı bu eşiğin üstünde olmalı (boş
  /// sayfa üretme hatasını yakalamak için) — `ImageExportVerification`'la aynı eşik ailesi.
  public static let minNonWhitePercentForNonEmpty: Double = 0.5

  /// `url`'in ilk sayfasını 150 dpi'de render edip beyaz-olmayan piksel oranını ölçer (yalnız
  /// "raster" kademesi için anlamlı — diğer kademelerde sayfa zaten vektör, bu ölçüt geçerli değil).
  /// Sayfa açılamıyorsa `nil`.
  public static func nonWhitePercent(_ url: URL) -> Double? {
    guard let doc = CGPDFDocument(url as CFURL), let page = doc.page(at: 1) else { return nil }
    let box = page.getBoxRect(.mediaBox)
    guard box.width > 0, box.height > 0 else { return nil }
    let scale: CGFloat = 150 / 72.0
    let width = max(1, Int((box.width * scale).rounded()))
    let height = max(1, Int((box.height * scale).rounded()))
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
    var nonWhite = 0
    for row in 0..<height {
      let rowStart = row * bytesPerRow
      for col in 0..<width where buffer[rowStart + col] < 250 { nonWhite += 1 }
    }
    return Double(nonWhite) / Double(width * height) * 100
  }

  /// Sayfa ölçüsü (MediaBox) kaynak ile çıktı arasında korunmuş mu — "raster" kademesinde ölçek/
  /// yuvarlama hatasını yakalamak için. `tolerancePoints` kadar farka izin verir.
  public static func pageSizeMatches(input: URL, output: URL, tolerancePoints: CGFloat = 1) -> Bool {
    guard
      let inDoc = CGPDFDocument(input as CFURL), let inPage = inDoc.page(at: 1),
      let outDoc = CGPDFDocument(output as CFURL), let outPage = outDoc.page(at: 1)
    else { return false }
    let inBox = inPage.getBoxRect(.mediaBox)
    let outBox = outPage.getBoxRect(.mediaBox)
    return abs(inBox.width - outBox.width) <= tolerancePoints
      && abs(inBox.height - outBox.height) <= tolerancePoints
  }
}
