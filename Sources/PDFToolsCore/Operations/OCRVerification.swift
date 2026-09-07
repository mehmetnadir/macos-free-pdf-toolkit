import CoreGraphics
import Foundation
import PDFKit
import Vision

/// "OCR ile Metin Çıkar" ve "Aranabilir PDF Yap"ın PAYLAŞTIĞI tarama çekirdeği + doğrulama —
/// `QRVerification`'ın QR Ekle/QR Ayıkla için oynadığı rolün AYNISI. Harici motor YOK — yalnızca
/// Apple'ın yerleşik Vision (`VNRecognizeTextRequest`) ve PDFKit çerçeveleri.
///
/// ÖLÇÜLMÜŞ ZEMİN (gerçek 5. sınıf Türkçe konu anlatım föyü, görselleştirilerek taranmış hâle
/// getirildi, bkz. `.claude/docs/yol-haritasi-2026-09.md` "Apple Vision OCR — Türkçe ölçümü"):
/// 200 dpi, `.accurate`, `usesLanguageCorrection = true` ile 45 satır, 1,03 sn, tüm satırlarda
/// güven 1,00, metin neredeyse birebir.
///
/// BİLİNEN HATA: noktalı büyük İ bazen noktasız I okunuyor (`METİNDE` → `METINDE`, aynı sayfada üç
/// `METİNDE`'den biri yanlış çıktı) — rastgele, kelimeye bağlı değil. Bu yüzden OCR çıktısının
/// `note`'unda bu uyarı KULLANICIYA gösterilir (bkz. `OCROperation.run`); "OCR yaptım, metin hazır"
/// gibi kesin bir dil KULLANILMAZ. Testlerde İ/I karşılaştırması normalize edilerek yapılır (bkz.
/// `Tur9Tests.containsIgnoringTurkishICase`).
public enum OCRVerification {
  /// Bir satır güveninin "kayda değer" sayılacağı alt sınır — yalnızca "en az bir satır makul
  /// güvenle okundu mu" kanıtı için (`OCROperation`'ın not satırındaki ortalama güvenden BAĞIMSIZ).
  public static let minConfidenceThreshold: Float = 0.3

  /// Tek bir tanınan metin satırı.
  public struct RecognizedLine: Sendable {
    public let text: String
    public let confidence: Float
    /// Vision'ın normalize sınırlayıcı kutusu: orijin SOL-ALT, 0...1 (`QRVerification.Detection`
    /// ile AYNI yön kuralı — ölçüldü, CoreGraphics/PDF sayfa uzayıyla örtüşüyor).
    public let boundingBox: CGRect
  }

  /// `page`'i `dpi`'de beyaz zemin üstüne render edip Vision ile üstündeki metni tanır. Sayfa
  /// kutusu dejenereyse ya da render başarısızsa boş dizi döner (hata FIRLATMAZ); Vision'ın
  /// `perform` çağrısı hata verirse o hatayı ÜST çağırana yansıtır (Vision içi bir hata gerçek
  /// arıza sayılır, "bulunamadı" ile karıştırılmaz).
  public static func recognizeText(
    onPage page: CGPDFPage, dpi: CGFloat, languages: [String],
    level: VNRequestTextRecognitionLevel, usesLanguageCorrection: Bool = true
  ) throws -> [RecognizedLine] {
    let box = page.getBoxRect(.mediaBox)
    guard box.width > 0, box.height > 0 else { return [] }
    let scale = dpi / 72.0
    let width = max(1, Int((box.width * scale).rounded(.up)))
    let height = max(1, Int((box.height * scale).rounded(.up)))
    guard
      let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return [] }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
    ctx.drawPDFPage(page)
    guard let image = ctx.makeImage() else { return [] }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = level
    request.recognitionLanguages = languages
    request.usesLanguageCorrection = usesLanguageCorrection
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    return (request.results ?? []).compactMap { observation in
      guard let candidate = observation.topCandidates(1).first else { return nil }
      return RecognizedLine(
        text: candidate.string, confidence: candidate.confidence,
        boundingBox: observation.boundingBox)
    }
  }

  /// PDFKit ile bir dosyada zaten (herhangi bir sayfada boş olmayan `page.string`) metin katmanı
  /// olup olmadığına bakar — `ExtractTextOperation`'ın kullandığı yöntemle AYNI.
  public static func hasExistingTextLayer(at url: URL) -> Bool {
    guard let document = PDFDocument(url: url) else { return false }
    for i in 0..<document.pageCount {
      if let text = document.page(at: i)?.string,
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        return true
      }
    }
    return false
  }

  /// "Aranabilir PDF Yap"ın ASIL kanıtı: çıktıyı PDFKit ile açıp `page.string`'in
  /// `expectedSubstring`'i GERÇEKTEN içerdiğini doğrular (görünmez ama SEÇİLEBİLİR/aranabilir
  /// metin — `QRAddOperation`'ın "QR çizildi ama okunmuyor" hatasını yakalayan `pageContains`
  /// gate'iyle AYNI mantık). Doküman/sayfa açılamazsa `false`. `pageIndex` 1-tabanlı.
  public static func searchablePageContains(
    pdfAt url: URL, pageIndex: Int, expectedSubstring: String
  ) -> Bool {
    guard let document = PDFDocument(url: url), let page = document.page(at: pageIndex - 1),
      let text = page.string
    else { return false }
    return text.contains(expectedSubstring)
  }

  private struct RenderedRGBA {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytes: [UInt8]
  }

  private static func renderRGBA(page: CGPDFPage, dpi: CGFloat) -> RenderedRGBA? {
    let box = page.getBoxRect(.mediaBox)
    guard box.width > 0, box.height > 0 else { return nil }
    let scale = dpi / 72.0
    let width = max(1, Int((box.width * scale).rounded(.up)))
    let height = max(1, Int((box.height * scale).rounded(.up)))
    guard
      let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
    ctx.drawPDFPage(page)
    guard let image = ctx.makeImage(), let dataProvider = image.dataProvider,
      let cfData = dataProvider.data, let ptr = CFDataGetBytePtr(cfData)
    else { return nil }
    let length = CFDataGetLength(cfData)
    let bytes = [UInt8](UnsafeBufferPointer(start: ptr, count: length))
    return RenderedRGBA(width: width, height: height, bytesPerRow: image.bytesPerRow, bytes: bytes)
  }

  /// İki sayfanın render edilmiş görüntüleri arasındaki ortalama (RGB, kanal başına, 0...1
  /// normalize) piksel farkı. "Aranabilir PDF Yap"ın görünmez metin katmanının görüntüyü
  /// DEĞİŞTİRMEDİĞİNİ kanıtlamak için kullanılır (`TrimVerification`'ın kalıntı-yüzdesi
  /// ölçümüyle AYNI "kutu üstverisine değil render edilen piksele bak" felsefesi). Render
  /// edilemezse ya da boyutlar uyuşmuyorsa `nil`.
  public static func averagePixelDifference(
    pageA: CGPDFPage, pageB: CGPDFPage, dpi: CGFloat = 150
  ) -> Double? {
    guard let a = renderRGBA(page: pageA, dpi: dpi), let b = renderRGBA(page: pageB, dpi: dpi),
      a.width == b.width, a.height == b.height
    else { return nil }
    var totalDiff = 0
    var sampleCount = 0
    for row in 0..<a.height {
      let rowA = row * a.bytesPerRow
      let rowB = row * b.bytesPerRow
      for col in 0..<a.width {
        for channel in 0..<3 {
          totalDiff += abs(
            Int(a.bytes[rowA + col * 4 + channel]) - Int(b.bytes[rowB + col * 4 + channel]))
          sampleCount += 1
        }
      }
    }
    guard sampleCount > 0 else { return nil }
    return Double(totalDiff) / Double(sampleCount) / 255.0
  }
}
