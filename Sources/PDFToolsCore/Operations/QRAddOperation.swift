import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Bir PDF'in her sayfasına (ya da yalnız ilk sayfasına) bir QR kod çizer. Harici motor YOK — QR
/// bitmap'i CoreImage'ın `CIFilter.qrCodeGenerator`'ıyla üretilir, kaynak PDF sayfa sayfa
/// CoreGraphics ile (bkz. `drawPDFPage`, `ImageExportOperation.renderPage` ile aynı üslup) yeni bir
/// PDF'e kopyalanır — bu yöntem sayfayı YENİDEN ÇİZDİĞİ için vektör içerik KORUNUR, rasterleştirme
/// YAPILMAZ. Çıktı soneki `_qr`.
///
/// Seçenekler: "content" bir `OperationOption` DEĞİLDİR — serbest metin (URL, vb.) olduğu için
/// `OperationContext.options[Self.contentOptionID]` üzerinden gelir (bkz. `PDFOperation.options`
/// tip yorumu: "genel bir form motoru İCAT EDİLMEDİ"). `position`/`size`/`pages` birer seçim
/// listesidir.
public struct QRAddOperation: PDFOperation {
  public static let identifier = "qradd"
  public let id = QRAddOperation.identifier
  public let title = "QR Ekle"
  public let subtitle = "Her sayfaya (ya da yalnız ilk sayfaya) bir QR kod çizer"
  public let systemImage = "qrcode"
  public let actionTitle = "QR Ekle"
  public let outputSuffix = "_qr"

  /// `OperationContext.options` anahtarı: QR'a kodlanacak serbest metin. Boşsa/verilmemişse
  /// `QRError.contentRequired` fırlatılır.
  public static let contentOptionID = "qrContent"
  public static let positionOptionID = "position"
  public static let sizeOptionID = "size"
  public static let pagesOptionID = "pages"

  /// QR'ın kenar uzunluğu (punto), `size` seçeneğine göre.
  private static let sizePoints: [String: CGFloat] = ["small": 36, "medium": 54, "large": 72]
  /// QR'ın sayfa kenarından uzaklığı (punto) — dört köşede de aynı.
  private static let margin: CGFloat = 12

  public init() {}

  public var options: [OperationOption] {
    [
      OperationOption(
        id: Self.positionOptionID, label: "Konum",
        choices: [("br", "Sağ alt"), ("bl", "Sol alt"), ("tr", "Sağ üst"), ("tl", "Sol üst")],
        defaultValue: "br"),
      OperationOption(
        id: Self.sizeOptionID, label: "Boyut",
        choices: [("small", "Küçük"), ("medium", "Orta"), ("large", "Büyük")],
        defaultValue: "medium"),
      OperationOption(
        id: Self.pagesOptionID, label: "Sayfalar",
        choices: [("all", "Tüm sayfalar"), ("first", "Yalnız ilk sayfa")],
        defaultValue: "all"),
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
    guard file.pageCount > 0 else {
      return .skipped(reason: "Sayfa yok")
    }

    let content =
      (context.options[Self.contentOptionID] ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !content.isEmpty else { throw QRError.contentRequired }

    let position = context.options[Self.positionOptionID] ?? "br"
    let sizeKey = context.options[Self.sizeOptionID] ?? "medium"
    let sizePt = Self.sizePoints[sizeKey] ?? Self.sizePoints["medium"]!
    let onlyFirstPage = (context.options[Self.pagesOptionID] ?? "all") == "first"

    guard let qrImage = Self.makeQRImage(content: content) else {
      throw QRError.generationFailed
    }
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
        document: document, total: total, qrImage: qrImage, position: position, sizePt: sizePt,
        onlyFirstPage: onlyFirstPage, to: partial, progress: progress)
    } catch is CancellationError {
      try? fm.removeItem(at: partial)
      throw CancellationError()
    } catch {
      try? fm.removeItem(at: partial)
      throw error
    }

    // Kanıt: çıktının QR'ı GERÇEKTEN okunuyor mu (bkz. `QRVerification` tip yorumu) — "QR çizildi
    // ama okunmuyor" hatasını yakalayan asıl kontrol. Yalnız 1. sayfa denetlenir: içerik/konum/
    // boyut her hedef sayfada AYNI olduğundan (bu sayede `TrimVerification`'ın "yalnız sayfa 1"
    // kararıyla aynı gerekçeyle) tek sayfa yeterli kanıt — "first" kipinde zaten QR'lı olan tek
    // sayfa budur, "all" kipinde de QR'lı ilk sayfa budur.
    guard QRVerification.pageContains(pdfAt: partial, pageIndex: 1, expectedContent: content) else {
      try? fm.removeItem(at: partial)
      throw QRError.verificationFailed
    }

    try fm.moveItem(at: partial, to: output)
    progress(1)
    return .produced(urls: [output], note: nil)
  }

  /// Kaynağın TÜM sayfalarını (kendi MediaBox'larıyla) yeni bir PDF'e kopyalar; `onlyFirstPage`
  /// yanlışsa her sayfaya, doğruysa yalnız 1. sayfaya QR çizer.
  private static func writeOutput(
    document: CGPDFDocument, total: Int, qrImage: CGImage, position: String, sizePt: CGFloat,
    onlyFirstPage: Bool, to url: URL, progress: @escaping @Sendable (Double) -> Void
  ) throws {
    var dummyBox = CGRect(x: 0, y: 0, width: 1, height: 1)
    guard let consumer = CGDataConsumer(url: url as CFURL) else { throw QRError.generationFailed }
    guard let ctx = CGContext(consumer: consumer, mediaBox: &dummyBox, nil) else {
      throw QRError.generationFailed
    }
    for pageIndex in 1...total {
      try Task.checkCancellation()
      guard let page = document.page(at: pageIndex) else { continue }
      // Her sayfa KENDİ MediaBox'ıyla açılır (bkz. `kCGPDFContextMediaBox` kullanımı) — ölçülüp
      // doğrulandı (scratchpad): tek dokümanda farklı sayfa boyutları olsa bile her biri aslına
      // sadık kopyalanıyor, tek bir varsayılan kutuya SIKIŞTIRILMIYOR.
      var box = page.getBoxRect(.mediaBox)
      let pageInfo: [CFString: Any] = [
        kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
      ]
      ctx.beginPDFPage(pageInfo as CFDictionary)
      ctx.drawPDFPage(page)
      if !onlyFirstPage || pageIndex == 1 {
        drawQR(qrImage, inPageBox: box, position: position, sizePt: sizePt, into: ctx)
      }
      ctx.endPDFPage()
      progress(Double(pageIndex) / Double(total))
    }
    ctx.closePDF()
  }

  private static func drawQR(
    _ image: CGImage, inPageBox box: CGRect, position: String, sizePt: CGFloat, into ctx: CGContext
  ) {
    let origin: CGPoint
    switch position {
    case "bl": origin = CGPoint(x: box.minX + margin, y: box.minY + margin)
    case "tr": origin = CGPoint(x: box.maxX - margin - sizePt, y: box.maxY - margin - sizePt)
    case "tl": origin = CGPoint(x: box.minX + margin, y: box.maxY - margin - sizePt)
    default: origin = CGPoint(x: box.maxX - margin - sizePt, y: box.minY + margin)  // "br"
    }
    let rect = CGRect(origin: origin, size: CGSize(width: sizePt, height: sizePt))
    ctx.saveGState()
    // Beyaz zemin (quiet zone): `makeQRImage`'ın ürettiği bitmap'in kendisi zaten quiet zone
    // İÇERİR (ölçüldü — bkz. o fonksiyonun yorumu), ama sayfa renkli/desenli olabilir; kontrastı
    // garantiye almak için kutunun altını AYRICA beyaza boyuyoruz.
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(rect)
    // Nearest-neighbor: `CIQRCodeGenerator` ham bitmap'i modül başına birkaç piksel civarında (bkz.
    // `makeQRImage` yorumu) üretir; düz (bilinear/lanczos) ölçekleme modül kenarlarını
    // bulanıklaştırıp taramayı zorlaştırabilir — bu yüzden bu çizimde interpolasyon KAPALI.
    ctx.interpolationQuality = .none
    ctx.draw(image, in: rect)
    ctx.restoreGState()
  }

  /// UTF-8 kodlamayla QR bitmap'i üretir (yalnız modül başına 1 piksellik ham render — hiç
  /// ölçeklenmemiş). UTF-8 seçimi KASITLI ve ÖLÇÜLDÜ (scratchpad): ISO-8859-1 (Latin-1) Türkçe
  /// karakterleri (ı, ğ, ş, İ, vb.) hiç KODLAYAMIYOR (encode başarısız oluyor); ISO/IEC 18004 QR
  /// standardı ECI/BOM olmadan ham UTF-8 baytlarını taşımaya izin veriyor ve Apple Vision bunu
  /// sorunsuz çözüyor — Türkçe + 260+ karakterlik içerik ölçümde birebir round-trip etti.
  /// `CIQRCodeGenerator`'ın ürettiği bitmap zaten standart quiet zone'u İÇERİR (ölçüldü: bir
  /// mesajın modül sayısına göre beklenen kare boyutuyla native piksel boyutu eşleşiyor).
  private static func makeQRImage(content: String) -> CGImage? {
    guard let data = content.data(using: .utf8) else { return nil }
    let filter = CIFilter.qrCodeGenerator()
    filter.message = data
    filter.correctionLevel = "M"
    guard let ciImage = filter.outputImage else { return nil }
    let ciContext = CIContext()
    return ciContext.createCGImage(ciImage, from: ciImage.extent)
  }
}

/// `QRAddOperation`'a özgü hatalar — `OperationError` (bkz. `PDFOperation.swift`) genel hata
/// kümesine EKLENMEDİ (o dosyaya dokunulmuyor, bkz. `PageEditOperation.PageEditError`'daki aynı
/// desen: işleme özgü hata kendi dosyasında).
public enum QRError: Error, LocalizedError, Equatable {
  /// `qrContent` boş ya da yalnız boşluk.
  case contentRequired
  /// `CIFilter.qrCodeGenerator` bitmap üretemedi (ör. içerik QR'ın taşıyabileceğinden uzun).
  case generationFailed
  /// `QRVerification.pageContains` çıktıyı okuyamadı; çıktı silinir.
  case verificationFailed

  public var errorDescription: String? {
    switch self {
    case .contentRequired: return "QR içeriği girin"
    case .generationFailed: return "QR görüntüsü üretilemedi — içerik çok uzun olabilir"
    case .verificationFailed: return "QR eklendi ama okunamadı — çıktı silindi"
    }
  }
}
