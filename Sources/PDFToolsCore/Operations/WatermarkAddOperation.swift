import CoreGraphics
import CoreText
import Foundation

/// PDF'in her sayfasına serbest metinli bir filigran çizer.
///
/// MOTOR KARARI (görev tanımının istediği gerekçe): pdfcpu'nun `watermark add --mode text`
/// komutu ÖNCE DENENDİ (`vendor/bin/pdfcpu watermark add --mode text "..." "pos:..., op:...,
/// points:..., fillcolor:..." in.pdf out.pdf` — söz dizimi `pdfcpu watermark add --help` ile
/// DOĞRULANDI), ama İKİ somut ölçülmüş sorun yüzünden ELENDİ; bunun yerine `QRAddOperation`'daki
/// sayfa-kopyalama deseniyle (CoreGraphics + CoreText, vektör KORUNUR, rasterleştirme YOK) gidildi:
///
/// 1) BAŞLIK/ALT BİLGİ KONUMUNDA METİN SESSİZCE KESİLİYOR (ölçüldü, 2026-09-08, gerçek pdfcpu
///    v0.15.0 dev ikilisiyle): `pos:tc` (üst-orta) ve `pos:bc` (alt-orta) çapaları, göreli
///    (`rel`) VEYA mutlak (`abs`) ölçek fark etmeksizin, metni SABİT genişlikte bir kutuya
///    sığdırıyor ve SIĞMAYAN kısmı satır kaydırmadan DOĞRUDAN ATIYOR (çıktı akışına hiç
///    yazılmıyor). Örnek: 612×792pt (Letter) sayfada 24pt Helvetica "TEST HEADER" (11 karakter)
///    `pos:tc`'de "TEST HEA" (ilk 8 karakter), `pos:bc`'de "T HEADER" (son 8 karakter) olarak
///    kesildi; AYNI metin `pos:c` (merkez, döndürmesiz) konumunda TAM okundu — yani sorun yalnız
///    kenar (üst/alt) çapalarında. Kullanıcının "İçerik" alanına yazdığı serbest bir filigran
///    metni "Üst bilgi"/"Alt bilgi" konumu seçildiğinde SESSİZCE kırpılabilir — kabul edilemez
///    bir sessiz veri kaybı (bkz. proje geneli Silent Catch Gate ilkesi).
/// 2) `PageNumberOperation`'ın `startAt=0` (kapak sayılmaz) ihtiyacı NEGATİF bir sayfa-numarası
///    kaydırması gerektiriyor; pdfcpu'nun `%p<N>` makrosu SADECE pozitif tam sayı kabul ediyor
///    (`%p1` ölçüldüğünde sayfa no'ya +1 ekliyor), `%p-1`/`%p_-1` söz dizimleri makro olarak hiç
///    PARSE EDİLMİYOR (literal metin olarak basılıyor, ölçüldü). Bu, bu dosyanın DOĞRUDAN
///    sorunu değil ama AYNI motorun aynı turdaki KARDEŞ işlemi (`PageNumberOperation`) için
///    yetersiz kaldığı ve iki işlemin TUTARLI aynı yaklaşımı (CoreGraphics) paylaşmasının kod
///    sağlığı açısından daha doğru olduğu anlamına geliyor — bkz. `PageNumberOperation.swift`
///    dosya üstü yorumundaki tam ölçüm.
///
/// pdfcpu'nun `%p`/`%P` makrolarının VARLIĞI ve ofsetsiz çalıştığı AYRICA doğrulandı (bkz.
/// `PageNumberOperation`); KISA metinlerde (ör. "5 / 120") `pos:bc`/`pos:br` konumunda kırpılma
/// GÖRÜLMEDİ — sorun yalnız UZUN serbest metin + kenar konumu birleşiminde ortaya çıkıyor, bu
/// yüzden pdfcpu sayfa-numarası makroları hâlâ "çalışıyor" ama serbest metinli filigran için
/// GÜVENİLMEZ.
///
/// Doğrulama motora (burada: kendi çizim kodumuza) da güvenmez — bkz. `WatermarkVerification`:
/// kaynak ve çıktı sayfası AYNI bölgede render edilip mürekkep oranı kıyaslanır.
///
/// Çıktı soneki `_filigranli`.
public struct WatermarkAddOperation: PDFOperation {
  public static let identifier = "watermarkadd"
  public let id = WatermarkAddOperation.identifier
  public let title = "Filigran Ekle"
  public let subtitle = "Her sayfaya serbest metinli bir filigran çizer"
  public let systemImage = "text.badge.plus"
  public let actionTitle = "Filigran Ekle"
  public let outputSuffix = "_filigranli"

  /// `OperationContext.options` anahtarı: filigrana yazılacak serbest metin — `QRAddOperation`
  /// `contentOptionID`'deki AYNI gerekçeyle bir `OperationOption` DEĞİL (serbest metin, seçim
  /// listesi değil; bkz. `PDFOperation.options` tip yorumu: "genel bir form motoru İCAT EDİLMEDİ").
  public static let textOptionID = "watermarkText"
  public static let positionOptionID = "position"
  public static let opacityOptionID = "opacity"
  public static let fontSizeOptionID = "fontSize"
  public static let colorOptionID = "color"

  private static let colorValues: [String: (r: CGFloat, g: CGFloat, b: CGFloat)] = [
    "gray": (0.5, 0.5, 0.5),
    "red": (0.75, 0.1, 0.1),
    "blue": (0.1, 0.2, 0.75),
  ]
  /// Sayfa kenarından metin taban çizgisine uzaklık (punto) — üst/alt bilgi konumları için.
  private static let edgeMargin: CGFloat = 28

  public init() {}

  public var options: [OperationOption] {
    [
      OperationOption(
        id: Self.positionOptionID, label: "Konum",
        choices: [("center", "Merkez (çapraz)"), ("header", "Üst bilgi"), ("footer", "Alt bilgi")],
        defaultValue: "center"),
      OperationOption(
        id: Self.opacityOptionID, label: "Opaklık",
        choices: [("0.15", "%15"), ("0.3", "%30"), ("0.5", "%50")], defaultValue: "0.15"),
      OperationOption(
        id: Self.fontSizeOptionID, label: "Yazı Boyutu",
        choices: [("24", "24 pt"), ("36", "36 pt"), ("48", "48 pt")], defaultValue: "36"),
      OperationOption(
        id: Self.colorOptionID, label: "Renk",
        choices: [("gray", "Gri"), ("red", "Kırmızı"), ("blue", "Mavi")], defaultValue: "gray"),
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
    guard file.pageCount > 0 else { return .skipped(reason: "Sayfa yok") }

    let text =
      (context.options[Self.textOptionID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw WatermarkError.textRequired }

    let position = context.options[Self.positionOptionID] ?? "center"
    let opacity = Double(context.options[Self.opacityOptionID] ?? "0.15") ?? 0.15
    let fontSize = CGFloat(Double(context.options[Self.fontSizeOptionID] ?? "36") ?? 36)
    let colorKey = context.options[Self.colorOptionID] ?? "gray"
    let rgb = Self.colorValues[colorKey] ?? Self.colorValues["gray"]!

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
        document: document, total: total, text: text, position: position, opacity: opacity,
        fontSize: fontSize, rgb: rgb, to: partial, progress: progress)
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
      throw WatermarkError.verificationFailed("sayfa sayısı korunmadı")
    }

    // Kanıt 2: filigran GERÇEKTEN beklenen bölgede mürekkep bırakmış mı — motora (kendi çizim
    // kodumuza) güvenilmiyor, kaynak ve çıktı AYNI bölgede render edilip kıyaslanıyor (bkz.
    // `WatermarkVerification`). Yalnız 1. sayfa denetlenir: konum/opaklık/renk her hedef sayfada
    // AYNI olduğundan (`QRAddOperation`'ın "her sayfada aynı" kararıyla aynı gerekçe) tek sayfa
    // yeterli kanıt.
    guard
      let delta = WatermarkVerification.delta(
        sourceURL: file.url, outputURL: partial, pageIndex: 1, position: position),
      delta >= WatermarkVerification.minDeltaPercent
    else {
      try? fm.removeItem(at: partial)
      throw WatermarkError.verificationFailed("filigran beklenen bölgede tespit edilemedi")
    }

    try fm.moveItem(at: partial, to: output)
    progress(1)
    return .produced(urls: [output], note: nil)
  }

  /// Kaynağın TÜM sayfalarını (kendi MediaBox'larıyla) yeni bir PDF'e kopyalar, her sayfaya
  /// filigranı çizer — `QRAddOperation.writeOutput` ile AYNI desen (vektör KORUNUR, rasterleştirme
  /// YOK).
  private static func writeOutput(
    document: CGPDFDocument, total: Int, text: String, position: String, opacity: Double,
    fontSize: CGFloat, rgb: (r: CGFloat, g: CGFloat, b: CGFloat), to url: URL,
    progress: @escaping @Sendable (Double) -> Void
  ) throws {
    var dummyBox = CGRect(x: 0, y: 0, width: 1, height: 1)
    guard let consumer = CGDataConsumer(url: url as CFURL) else {
      throw WatermarkError.generationFailed("veri tüketicisi oluşturulamadı")
    }
    guard let ctx = CGContext(consumer: consumer, mediaBox: &dummyBox, nil) else {
      throw WatermarkError.generationFailed("PDF bağlamı oluşturulamadı")
    }
    let color = CGColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: opacity)
    let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
    let attrs: [CFString: Any] = [
      kCTFontAttributeName: font, kCTForegroundColorAttributeName: color,
    ]
    guard let attrString = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)
    else {
      throw WatermarkError.generationFailed("metin nesnesi oluşturulamadı")
    }
    let line = CTLineCreateWithAttributedString(attrString)
    let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))

    for pageIndex in 1...total {
      try Task.checkCancellation()
      guard let page = document.page(at: pageIndex) else { continue }
      var box = page.getBoxRect(.mediaBox)
      let pageInfo: [CFString: Any] = [
        kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
      ]
      ctx.beginPDFPage(pageInfo as CFDictionary)
      ctx.drawPDFPage(page)
      ctx.saveGState()
      switch position {
      case "header":
        ctx.textPosition = CGPoint(x: box.midX - lineWidth / 2, y: box.maxY - edgeMargin - fontSize)
        CTLineDraw(line, ctx)
      case "footer":
        ctx.textPosition = CGPoint(x: box.midX - lineWidth / 2, y: box.minY + edgeMargin)
        CTLineDraw(line, ctx)
      default:  // "center" — çapraz (45°), sayfa ortasından geçer.
        ctx.translateBy(x: box.midX, y: box.midY)
        ctx.rotate(by: .pi / 4)
        ctx.textPosition = CGPoint(x: -lineWidth / 2, y: 0)
        CTLineDraw(line, ctx)
      }
      ctx.restoreGState()
      ctx.endPDFPage()
      progress(Double(pageIndex) / Double(total))
    }
    ctx.closePDF()
  }
}

/// `WatermarkAddOperation`'a özgü hatalar — `OperationError`'a EKLENMEDİ (bkz. `QRError`/
/// `CompressError` aynı desen: işleme özgü hata kendi dosyasında, `PDFOperation.swift`'e
/// dokunulmuyor).
public enum WatermarkError: Error, LocalizedError, Equatable {
  /// Filigran metni boş ya da yalnız boşluk.
  case textRequired
  /// PDF üretim aşaması başarısız (CGContext/consumer/metin nesnesi kurulamadı).
  case generationFailed(String)
  /// `WatermarkVerification` beklenen bölgede yeterli mürekkep artışı bulamadı; çıktı silinir.
  case verificationFailed(String)

  public var errorDescription: String? {
    switch self {
    case .textRequired: return "Filigran metni girin"
    case .generationFailed(let detail): return "Filigran üretilemedi — \(detail)"
    case .verificationFailed(let detail):
      return "Filigran doğrulanamadı — \(detail) — çıktı silindi"
    }
  }
}
