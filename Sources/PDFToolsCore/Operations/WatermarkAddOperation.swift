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
/// Çıktı soneki `_watermarked`.
public struct WatermarkAddOperation: PDFOperation {
  public static let identifier = "watermarkadd"
  public let id = WatermarkAddOperation.identifier
  public let title = "Add Watermark"
  public let subtitle = "Draws a custom text watermark on every page"
  public let systemImage = "text.badge.plus"
  public let actionTitle = "Add Watermark"
  public let outputSuffix = "_watermarked"
  public var outputSuffixes: [String] { [outputSuffix] }

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

  /// YALNIZCA TEST İÇİN: `true` iken metin GERÇEKTEN ÇİZİLMEZ (`CTLineDraw` atlanır) — döndürme/
  /// konum/renk/alfa durumu ve sayfa sayısı AYNI kalır, yalnız glif gösterme operatörü hiç
  /// üretilmez. `WatermarkVerification`'ın yapısal kapısının GERÇEKTEN "filigran çizilmedi"
  /// durumunu yakaladığını kanıtlayan MUTASYON testi için var — kendi çizim kodumuzu bilerek
  /// bozup kapının hâlâ düştüğünü görmeden "kapı çalışıyor" denemez (bkz. proje geneli ilke).
  /// Varsayılan `false`; yalnız `@testable import` ile erişilebilir, üretim akışına asla true
  /// olarak girmez.
  static var testingSkipTextDraw = false

  public init() {}

  public var options: [OperationOption] {
    [
      OperationOption(
        id: Self.positionOptionID, label: "Position",
        choices: [("center", "Center (diagonal)"), ("header", "Header"), ("footer", "Footer")],
        defaultValue: "center"),
      OperationOption(
        id: Self.opacityOptionID, label: "Opacity",
        choices: [("0.15", "15% — subtle"), ("0.3", "30% — noticeable"), ("0.5", "50% — bold")],
        defaultValue: "0.15"),
      OperationOption(
        id: Self.fontSizeOptionID, label: "Font Size",
        choices: [("24", "24 pt — small"), ("36", "36 pt — medium"), ("48", "48 pt — large")],
        defaultValue: "36"),
      OperationOption(
        id: Self.colorOptionID, label: "Color",
        choices: [("gray", "Gray"), ("red", "Red"), ("blue", "Blue")], defaultValue: "gray"),
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
    let fm = FileManager.default

    // GÜVENLİK: `writeOutput` bir `CGDataConsumer(url:)` üzerinden CoreGraphics'in KENDİSİ
    // tarafından oluşturulan bir dosyaya yazıyor — `TempArtifact.withPrivateDirectory` kullanılıyor
    // (bkz. o tipin gerekçesi).
    return try await TempArtifact.withPrivateDirectory(
      in: output.deletingLastPathComponent()
    ) { tempDir in
      let partial = tempDir.appendingPathComponent("output.pdf")
      try Self.writeOutput(
        document: document, total: total, text: text, position: position, opacity: opacity,
        fontSize: fontSize, rgb: rgb, to: partial, progress: progress)

      // Kanıt 1: sayfa sayısı korunmuş.
      guard let outDoc = CGPDFDocument(partial as CFURL), outDoc.numberOfPages == total else {
        throw WatermarkError.verificationFailed("page count wasn't preserved")
      }

      // NOT (çakışma çözümü 29.09): geçici çıktı artık `TempArtifact.withPrivateDirectory`
      // içinde yaşıyor, kapanışta kendiliğinden siliniyor — reddedilen çıktıyı elle silen
      // `fm.removeItem` çağrıları bu yüzden kaldırıldı.
      // Kanıt 2: filigran GERÇEKTEN beklenen bölgede çizilmiş mi — motora (kendi çizim kodumuza)
      // güvenilmiyor. İKİ BAĞIMSIZ EKSEN (ölçüldü, 2026-09-29 — gerçek yoğun/renkli dosyalarda
      // piksel eşiği TEK BAŞINA SATÜRE oluyor, bkz. `WatermarkVerification` dosya üstü notu):
      //   2a. YAPISAL (BİRİNCİL): çıktının içerik akışında GERÇEKTEN bir metin gösterme operatörü
      //       var mı, beklenen konumun geometrisiyle (merkezde 45° döndürme, üst/altta doğru yarı)
      //       uyumlu mu — `WatermarkStructuralCheck`. Ölçülemezse (qpdf yok, akış okunamadı)
      //       FAIL-CLOSED: "geçti" değil "düştü" denir.
      //   2b. PİKSEL (İKİNCİL/doğrulayıcı): çıktı−kaynak mürekkep farkı SIFIR (ya da negatif)
      //       DEĞİL mi — yapısal kanıt varken render tamamen bozuksa (ör. renk uzayı feci
      //       hasarlı) yine de reddeder.
      // Yalnız 1. sayfa denetlenir: konum/opaklık/renk her hedef sayfada AYNI olduğundan
      // (`QRAddOperation`'ın "her sayfada aynı" kararıyla aynı gerekçe) tek sayfa yeterli kanıt.
      let structuralPassed: Bool
      do {
        guard let qpdf = EngineLocator.find("qpdf") else {
            throw WatermarkError.verificationFailed("qpdf engine not found — could not verify")
        }
        guard
          let evidence = try await WatermarkVerification.structuralTextWasDrawn(
            outputURL: partial, pageIndex: 1, position: position, qpdf: qpdf)
        else {
            throw WatermarkError.verificationFailed(
            "watermark content stream could not be verified")
        }
        structuralPassed = evidence
      } catch let error as WatermarkError {
        throw error
      } catch {
        throw WatermarkError.verificationFailed(
          "watermark content stream could not be verified — \(error.localizedDescription)")
      }
      let pixelDelta = WatermarkVerification.delta(
        sourceURL: file.url, outputURL: partial, pageIndex: 1, position: position)
      guard structuralPassed, let pixelDelta, pixelDelta > 0 else {
        throw WatermarkError.verificationFailed("watermark wasn't detected in the expected area")
      }

      // YENİDEN ÇİZMENİN ORTAK SON ADIMI (bkz. `RewriteOutput` gerekçesi): bu işlem sayfayı
      // CoreGraphics ile yeniden çiziyor; ölçüldüğünde çıktının xref'i kırılıyor (gerçek bir
      // matbaa dosyasında 64 nesne "offset 0"), sürüm düşüyor ve XMP üstverisi siliniyor. Onarım +
      // yapı kapısı burada; kalan hasar sonuç satırında SÖYLENİYOR, sessizce yutulmuyor.
      let rewrite = try await RewriteOutput.finish(output: partial, source: file.url)

      try fm.moveItem(at: partial, to: output)
      progress(1)
      return .produced(urls: [output], note: rewrite.note)
    }
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
      throw WatermarkError.generationFailed("could not create the data consumer")
    }
    guard let ctx = CGContext(consumer: consumer, mediaBox: &dummyBox, nil) else {
      throw WatermarkError.generationFailed("could not create the PDF context")
    }
    let color = CGColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: opacity)
    let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
    let attrs: [CFString: Any] = [
      kCTFontAttributeName: font, kCTForegroundColorAttributeName: color,
    ]
    guard let attrString = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)
    else {
      throw WatermarkError.generationFailed("could not create the text object")
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
        if !testingSkipTextDraw { CTLineDraw(line, ctx) }
      case "footer":
        ctx.textPosition = CGPoint(x: box.midX - lineWidth / 2, y: box.minY + edgeMargin)
        if !testingSkipTextDraw { CTLineDraw(line, ctx) }
      default:  // "center" — çapraz (45°), sayfa ortasından geçer.
        ctx.translateBy(x: box.midX, y: box.midY)
        ctx.rotate(by: .pi / 4)
        ctx.textPosition = CGPoint(x: -lineWidth / 2, y: 0)
        if !testingSkipTextDraw { CTLineDraw(line, ctx) }
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
    case .textRequired: return "Enter watermark text"
    case .generationFailed(let detail): return "Could not generate the watermark — \(detail)"
    case .verificationFailed(let detail):
      return "Watermark could not be verified — \(detail) — output deleted"
    }
  }
}
