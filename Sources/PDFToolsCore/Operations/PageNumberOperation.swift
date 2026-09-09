import CoreGraphics
import CoreText
import Foundation

/// PDF'in her sayfasına (isteğe bağlı olarak kapak hariç) bir sayfa numarası çizer.
///
/// MOTOR KARARI: pdfcpu'nun `watermark add --mode text` komutu, `%p`/`%P` (geçerli sayfa/toplam
/// sayfa) makrolarıyla ÖNCE DENENDİ ve makroların VARLIĞI DOĞRULANDI (ölçüldü, 2026-09-08, gerçek
/// pdfcpu v0.15.0 dev ikilisiyle): `"%p"` → gerçek sayfa no, `"%p / %P"` → "1 / 6" gibi doğru
/// "N / M" dizeleri üretti; KISA metinlerde `pos:bc`/`pos:br` (alt-orta/alt-sağ) konumunda
/// kırpılma GÖRÜLMEDİ. Varsayılan (`startAt=1`, kapak dahil) durum için pdfcpu FİİLEN ÇALIŞIYORDU.
///
/// Ama `startAt=0` (kapak sayılmaz — 1. sayfa numarasız, 2. sayfa "1" göstermeli) NEGATİF bir
/// kaydırma gerektiriyor; pdfcpu'nun `%p<N>` söz dizimi SADECE pozitif tam sayı kabul ediyor:
///   - `%p1` → sayfa no'ya +1 ekledi (sayfa 1 → "2") — DOĞRULANDI.
///   - `%p-1` → makro olarak hiç PARSE EDİLMEDİ, "%p" (ofset 0) + literal "-1" olarak basıldı
///     (çıktı "2-1" gibi) — DOĞRULANDI.
///   - `%p_-1`, `%p_1` gibi alt çizgili varyantlar da denendi (ikili strings'te `%p_i`/`%P_i`
///     iç format izleri bulundu); `%p_1` beklenmedik biçimde TÜM sayfalarda SABİT "1" bastı
///     (artan değil), negatif söz dizimi yine literal metin olarak kaldı — güvenilir bir
///     negatif-ofset yolu bulunamadı.
/// Bu yüzden `startAt=0` desteklenemedi ve — kod tutarlılığı için AYNI kararı
/// `WatermarkAddOperation` için de geçerli kılan ayrı bir ölçülmüş sorunla birlikte (bkz. o
/// dosyanın üst yorumu: başlık/alt bilgi konumunda UZUN metin sessizce kırpılıyor) — bu işlem
/// `QRAddOperation`'daki sayfa-kopyalama deseniyle (CoreGraphics + CoreText, vektör KORUNUR)
/// CoreGraphics'e gitti. Bu yaklaşım `startAt`, `format` ve beş konumun TAMAMINI tek, test
/// edilebilir bir yerden (bkz. `PageNumberVerification`) üretir.
///
/// Doğrulama: sayfa sayısı korunur VE PDFKit ile metin GERİ OKUNUP beklenen numaranın GERÇEKTEN
/// geçtiği (ya da kapak sayfasında HİÇ numara olmadığı) doğrulanır — bkz. `PageNumberVerification`.
///
/// Çıktı soneki `_numbered`.
public struct PageNumberOperation: PDFOperation {
  public static let identifier = "pagenumber"
  public let id = PageNumberOperation.identifier
  public let title = "Add Page Numbers"
  public let subtitle = "Draws a page number on every page (optionally excluding the cover)"
  public let systemImage = "list.number"
  public let actionTitle = "Add Page Numbers"
  public let outputSuffix = "_numbered"
  public var outputSuffixes: [String] { [outputSuffix] }

  public static let positionOptionID = "position"
  public static let startAtOptionID = "startAt"
  public static let formatOptionID = "format"

  private static let fontSize: CGFloat = 10
  /// Sayfa kenarından metin taban çizgisine (ya da üst konumlarda tepe noktasına) uzaklık
  /// (punto).
  private static let edgeMargin: CGFloat = 20

  public init() {}

  public var options: [OperationOption] {
    [
      OperationOption(
        id: Self.positionOptionID, label: "Position",
        choices: [
          ("footer-center", "Bottom center"), ("footer-right", "Bottom right"),
          ("footer-left", "Bottom left"),
          ("header-center", "Top center"), ("header-right", "Top right"),
        ], defaultValue: "footer-center"),
      OperationOption(
        id: Self.startAtOptionID, label: "Start",
        choices: [("1", "From 1 (cover included)"), ("0", "Cover not counted")], defaultValue: "1"),
      OperationOption(
        id: Self.formatOptionID, label: "Format",
        choices: [
          ("plain", "Number only (e.g. \"5\")"), ("ofN", "Number and total (e.g. \"5 / 120\")"),
        ], defaultValue: "ofN"),
    ]
  }

  public func run(
    file: PDFFileInfo, context: OperationContext,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> OperationOutcome {
    switch file.lockState {
    case .unreadable: throw OperationError.unreadable
    case .passwordRequired: throw OperationError.passwordRequired
    case .restricted, .none: break
    }
    guard file.pageCount > 0 else { return .skipped(reason: "No pages") }

    let position = context.options[Self.positionOptionID] ?? "footer-center"
    let startAt = context.options[Self.startAtOptionID] ?? "1"
    let format = context.options[Self.formatOptionID] ?? "ofN"

    guard let document = CGPDFDocument(file.url as CFURL), document.isUnlocked else {
      throw OperationError.unreadable
    }
    let total = document.numberOfPages

    let output = OutputNaming.uniqueURL(
      for: file.url, suffix: outputSuffix, in: context.outputDirectory)
    let partial = output.deletingLastPathComponent()
      .appendingPathComponent(".\(output.deletingPathExtension().lastPathComponent).part.pdf")
    let fm = FileManager.default
    try? fm.removeItem(at: partial)

    do {
      try Self.writeOutput(
        document: document, total: total, position: position, startAt: startAt, format: format,
        to: partial, progress: progress)
    } catch is CancellationError {
      try? fm.removeItem(at: partial)
      throw CancellationError()
    } catch {
      try? fm.removeItem(at: partial)
      throw error
    }

    // Kanıt 1: sayfa sayısı korunmuş.
    guard let outDoc = CGPDFDocument(partial as CFURL), outDoc.numberOfPages == total else {
      try? fm.removeItem(at: partial)
      throw PageNumberError.verificationFailed("page count wasn't preserved")
    }

    // Kanıt 2: PDFKit ile metin GERİ OKUNUP beklenen numaranın GERÇEKTEN geçtiği doğrulanır —
    // kendi çizim kodumuza güvenilmiyor (bkz. `PageNumberVerification`, kapsam-sınırı notu için
    // tip yorumuna bakın). İlk VE son sayfa örneklenir: `startAt=0`'da 1. sayfanın numarasız
    // KALMASI ayrı bir iddiadır, yalnız bir sayfa (`QRAddOperation`'ın tek-sayfa gerekçesinin
    // aksine) yeterli değil.
    for pageIndex in Set([1, total]) {
      guard
        let ok = PageNumberVerification.pageMatchesExpectation(
          pdfAt: partial, pageIndex: pageIndex, total: total, startAt: startAt, format: format)
      else {
        try? fm.removeItem(at: partial)
        throw PageNumberError.verificationFailed("page \(pageIndex) could not be read")
      }
      guard ok else {
        try? fm.removeItem(at: partial)
        throw PageNumberError.verificationFailed(
          "page \(pageIndex) doesn't contain the expected number")
      }
    }

    try fm.moveItem(at: partial, to: output)
    progress(1)
    return .produced(urls: [output], note: nil)
  }

  /// Kaynağın TÜM sayfalarını (kendi MediaBox'larıyla) yeni bir PDF'e kopyalar, gerektiğinde
  /// (`PageNumberVerification.expectedText` `nil` DÖNMEDİĞİ sürece) numarayı çizer —
  /// `QRAddOperation.writeOutput` ile AYNI desen (vektör KORUNUR, rasterleştirme YOK).
  private static func writeOutput(
    document: CGPDFDocument, total: Int, position: String, startAt: String, format: String,
    to url: URL, progress: @escaping @Sendable (Double) -> Void
  ) throws {
    var dummyBox = CGRect(x: 0, y: 0, width: 1, height: 1)
    guard let consumer = CGDataConsumer(url: url as CFURL) else {
      throw PageNumberError.generationFailed("could not create the data consumer")
    }
    guard let ctx = CGContext(consumer: consumer, mediaBox: &dummyBox, nil) else {
      throw PageNumberError.generationFailed("could not create the PDF context")
    }
    let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
    let color = CGColor(gray: 0.15, alpha: 1)

    for pageIndex in 1...total {
      try Task.checkCancellation()
      guard let page = document.page(at: pageIndex) else { continue }
      var box = page.getBoxRect(.mediaBox)
      let pageInfo: [CFString: Any] = [
        kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
      ]
      ctx.beginPDFPage(pageInfo as CFDictionary)
      ctx.drawPDFPage(page)

      if let text = PageNumberVerification.expectedText(
        forPage: pageIndex, total: total, startAt: startAt, format: format)
      {
        let attrs: [CFString: Any] = [
          kCTFontAttributeName: font, kCTForegroundColorAttributeName: color,
        ]
        guard
          let attrString = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)
        else {
          throw PageNumberError.generationFailed("could not create the text object")
        }
        let line = CTLineCreateWithAttributedString(attrString)
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        ctx.saveGState()
        switch position {
        case "footer-right":
          ctx.textPosition = CGPoint(x: box.maxX - edgeMargin - lineWidth, y: box.minY + edgeMargin)
        case "footer-left":
          ctx.textPosition = CGPoint(x: box.minX + edgeMargin, y: box.minY + edgeMargin)
        case "header-center":
          ctx.textPosition = CGPoint(
            x: box.midX - lineWidth / 2, y: box.maxY - edgeMargin - fontSize)
        case "header-right":
          ctx.textPosition = CGPoint(
            x: box.maxX - edgeMargin - lineWidth, y: box.maxY - edgeMargin - fontSize)
        default:  // "footer-center"
          ctx.textPosition = CGPoint(x: box.midX - lineWidth / 2, y: box.minY + edgeMargin)
        }
        CTLineDraw(line, ctx)
        ctx.restoreGState()
      }
      ctx.endPDFPage()
      progress(Double(pageIndex) / Double(total))
    }
    ctx.closePDF()
  }
}

/// `PageNumberOperation`'a özgü hatalar — `OperationError`'a EKLENMEDİ (bkz. `QRError`/
/// `CompressError` aynı desen).
public enum PageNumberError: Error, LocalizedError, Equatable {
  case generationFailed(String)
  case verificationFailed(String)

  public var errorDescription: String? {
    switch self {
    case .generationFailed(let detail): return "Could not generate the page number — \(detail)"
    case .verificationFailed(let detail):
      return "Page number could not be verified — \(detail) — output deleted"
    }
  }
}
