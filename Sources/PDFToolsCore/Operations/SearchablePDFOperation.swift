import CoreGraphics
import CoreText
import Foundation
import Vision

/// Taranmış bir PDF'in ÜSTÜNE görünmez bir metin katmanı ekler: görüntü aynen kalır, ama sayfa
/// artık aranabilir/seçilebilir. Yöntem: her sayfa CoreGraphics ile yeni PDF'e kopyalanır
/// (`QRAddOperation.writeOutput` ile AYNI "sayfayı yeniden çiz, rasterleştirme YAPMA" deseni —
/// varsa vektör içerik KORUNUR), sonra `OCRVerification.recognizeText`'in bulduğu her satır için
/// metin, PDF metin render kipi 3 (`Tr 3`, "ne dolgu ne çizgi") ile — `CGContext.
/// setTextDrawingMode(.invisible)` + CoreText `CTLineDraw` — GÖRÜNMEZ ama SEÇİLEBİLİR biçimde
/// çizilir. Harici motor YOK, model indirme YOK, API anahtarı YOK.
///
/// Font harfi harfine hizalanmaz (görev tanımı bunu şart koşmuyor) — Vision'ın satır kutusu
/// (`boundingBox`, normalize, orijin SOL-ALT) yüksekliğine göre TEK bir punto boyutu seçilir ve
/// satırın tamamı o kutunun sol-alt köşesinden başlayarak çizilir; bu, arama/seçim için yeterli
/// hizalama sağlar (bkz. `QRVerification.Detection` ile AYNI koordinat kuralı).
///
/// DOĞRULAMA: çıktı `.part.pdf`'ten final ada taşınmadan önce `OCRVerification.
/// searchablePageContains` ile GERÇEKTEN sınanır — `QRAddOperation`'ın "QR çizildi ama okunmuyor"
/// hatasını yakalayan gate'iyle AYNI mantık ("metin eklendi ama aranamıyor" hatasını yakalar).
public struct SearchablePDFOperation: PDFOperation {
  public static let identifier = "searchablepdf"
  public let id = SearchablePDFOperation.identifier
  public let title = "Make Searchable"
  public let subtitle = "Adds an invisible text layer to the scanned PDF so it becomes searchable"
  public let systemImage = "doc.text.magnifyingglass"
  public let actionTitle = "Make Searchable"
  public let outputSuffix = "_searchable"
  public var outputSuffixes: [String] { [outputSuffix] }

  public init() {}

  public var options: [OperationOption] {
    [
      OperationOption(
        id: OCROperation.languageOptionID, label: "Language", choices: OCROperation.languageChoices,
        defaultValue: "tr"),
      OperationOption(
        id: OCROperation.dpiOptionID, label: "Resolution", choices: OCROperation.dpiChoices,
        defaultValue: "200"),
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
    guard let document = CGPDFDocument(file.url as CFURL), document.isUnlocked else {
      throw OperationError.unreadable
    }
    let total = document.numberOfPages
    guard total > 0 else { return .skipped(reason: "No pages") }

    let languageKey = context.options[OCROperation.languageOptionID] ?? "tr"
    let languages =
      OCROperation.recognitionLanguages[languageKey] ?? OCROperation.recognitionLanguages["tr"]!
    let dpi = CGFloat(Double(context.options[OCROperation.dpiOptionID] ?? "200") ?? 200)

    let output = OutputNaming.uniqueURL(
      for: file.url, suffix: outputSuffix, in: context.outputDirectory)
    let partial = output.deletingLastPathComponent()
      .appendingPathComponent(".\(output.deletingPathExtension().lastPathComponent).part.pdf")
    let fm = FileManager.default
    try? fm.removeItem(at: partial)

    let samples: [(pageIndex: Int, sampleText: String)]
    let sawTurkishDiacritic: Bool
    do {
      (samples, sawTurkishDiacritic) = try Self.writeOutput(
        document: document, total: total, languages: languages, dpi: dpi, to: partial,
        progress: progress)
    } catch is CancellationError {
      try? fm.removeItem(at: partial)
      throw CancellationError()
    } catch {
      try? fm.removeItem(at: partial)
      throw error
    }

    guard let firstSample = samples.first else {
      try? fm.removeItem(at: partial)
      return .skipped(reason: "No text recognized — pages may be blank or too low quality to read")
    }

    // Kanıt: görünmez metin GERÇEKTEN seçilebilir/aranabilir mi (bkz. dosya üstü yorum).
    guard
      OCRVerification.searchablePageContains(
        pdfAt: partial, pageIndex: firstSample.pageIndex,
        expectedSubstring: firstSample.sampleText)
    else {
      try? fm.removeItem(at: partial)
      throw SearchablePDFError.verificationFailed
    }

    // YENİDEN ÇİZMENİN ORTAK SON ADIMI (bkz. `RewriteOutput` gerekçesi): bu işlem sayfayı
    // CoreGraphics ile yeniden çiziyor; ölçüldüğünde çıktının xref'i kırılıyor (gerçek bir matbaa
    // dosyasında 64 nesne "offset 0"), sürüm düşüyor ve XMP üstverisi siliniyor. Onarım + yapı
    // kapısı burada; kalan hasar sonuç satırında SÖYLENİYOR, sessizce yutulmuyor.
    let rewrite: RewriteOutput.Report
    do {
      rewrite = try await RewriteOutput.finish(output: partial, source: file.url)
    } catch {
      try? fm.removeItem(at: partial)
      throw error
    }

    try fm.moveItem(at: partial, to: output)
    progress(1)

    // İKİ BAĞIMSIZ sinyal — bkz. `OCRVerification` dosya üstü CI ölçümü (GitHub macos-15 runner,
    // 2026-09-08): bu makinede Vision'ın tr-TR'ye sessizce düşmediğinden emin olunamıyorsa YA DA
    // GERÇEK tanınan metinde hiç Türkçe aksanlı harf yoksa, eklenen metin GÖRÜNMEZ katmanda
    // sessizce bozuk kalabilir — kullanıcı bunu göremez (metin zaten görünmez). `sawTurkishDiacritic`
    // burada `OCRVerification.containsTurkishDiacritic`'in `writeOutput` döngüsünde satır satır
    // OR'lanmış hâli — tüm sayfa metnini bellekte tutmadan AYNI ikinci sinyali verir.
    let requestsTurkish = languageKey == "tr" || languageKey == "auto"
    var note: String?
    if requestsTurkish {
      let missingFromSupportedList = !OCRVerification.allLanguagesSupported(
        ["tr-TR"], level: .accurate)
      if missingFromSupportedList || !sawTurkishDiacritic {
        note = OCROperation.turkishSupportWarning
      }
    }
    // Yeniden çizme hasarı (varsa) OCR uyarısıyla birlikte bildirilir — biri diğerini bastırmaz.
    let notes = [note, rewrite.note].compactMap { $0 }
    return .produced(urls: [output], note: notes.isEmpty ? nil : notes.joined(separator: " · "))
  }

  /// Kaynağın TÜM sayfalarını (kendi MediaBox'larıyla) yeni bir PDF'e kopyalar, her sayfada Vision
  /// ile metni tanır ve görünmez biçimde üstüne çizer. Her sayfa için ilk tanınan (boş olmayan)
  /// satırı `samples`'a ekler — `run()`'daki doğrulama gate'i bunu kullanır (görev tanımındaki
  /// "OCR'ın bulduğu belirgin bir kelimenin ORADA olduğunu doğrula" kanıtının girdisi).
  /// `sawTurkishDiacritic`: TÜM sayfalardaki TÜM satırlarda en az bir Türkçe aksanlı harf (ş/ğ/İ/
  /// ı/Ş/Ğ) görüldü mü — Türkçe dil desteği bozukluğunun ikinci sinyali (bkz. `run()`), metni
  /// bellekte biriktirmeden tek bir bayrakla izlenir.
  private static func writeOutput(
    document: CGPDFDocument, total: Int, languages: [String], dpi: CGFloat, to url: URL,
    progress: @escaping @Sendable (Double) -> Void
  ) throws -> (samples: [(pageIndex: Int, sampleText: String)], sawTurkishDiacritic: Bool) {
    var dummyBox = CGRect(x: 0, y: 0, width: 1, height: 1)
    guard let consumer = CGDataConsumer(url: url as CFURL) else {
      throw SearchablePDFError.generationFailed
    }
    guard let ctx = CGContext(consumer: consumer, mediaBox: &dummyBox, nil) else {
      throw SearchablePDFError.generationFailed
    }
    var samples: [(pageIndex: Int, sampleText: String)] = []
    var sawTurkishDiacritic = false
    for pageIndex in 1...total {
      try Task.checkCancellation()
      guard let page = document.page(at: pageIndex) else { continue }
      // Her sayfa KENDİ MediaBox'ıyla açılır — `QRAddOperation.writeOutput` ile AYNI, ölçülüp
      // doğrulanmış desen (bkz. o dosyadaki yorum): farklı sayfa boyutları da aslına sadık kopyalanır.
      var box = page.getBoxRect(.mediaBox)
      let pageInfo: [CFString: Any] = [
        kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
      ]
      ctx.beginPDFPage(pageInfo as CFDictionary)
      ctx.drawPDFPage(page)

      // Döngü içinde: tanıma sırasındaki render bitmap'i yalnızca bu iterasyon boyunca yaşar —
      // aynı anda TEK sayfalık görüntü bellekte (bkz. `ImageExportOperation` ile AYNI gerekçe).
      let lines = try OCRVerification.recognizeText(
        onPage: page, dpi: dpi, languages: languages, level: .accurate)
      var firstNonEmpty: String?
      for line in lines {
        let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        if firstNonEmpty == nil { firstNonEmpty = trimmed }
        if !sawTurkishDiacritic, OCRVerification.containsTurkishDiacritic(trimmed) {
          sawTurkishDiacritic = true
        }
        drawInvisibleText(trimmed, boundingBox: line.boundingBox, inPageBox: box, into: ctx)
      }
      if let sample = firstNonEmpty { samples.append((pageIndex, sample)) }

      ctx.endPDFPage()
      progress(Double(pageIndex) / Double(total))
    }
    ctx.closePDF()
    return (samples, sawTurkishDiacritic)
  }

  /// Vision'ın normalize (orijin SOL-ALT, 0...1) satır kutusunu sayfa punto uzayına çevirip metni
  /// `Tr 3` (ne dolgu ne çizgi) render kipiyle GÖRÜNMEZ çizer — çizim GERÇEKTEN yapılır (aksi
  /// halde PDFKit'in `page.string`'i metni hiç bulamaz), yalnız pikselde iz bırakmaz (ölçülüp
  /// `Tur9Tests`'te doğrulandı: kaynakla çıktı arasındaki ortalama piksel farkı ihmal edilebilir).
  private static func drawInvisibleText(
    _ text: String, boundingBox normalizedBox: CGRect, inPageBox box: CGRect, into ctx: CGContext
  ) {
    let rect = CGRect(
      x: box.minX + normalizedBox.minX * box.width,
      y: box.minY + normalizedBox.minY * box.height,
      width: normalizedBox.width * box.width,
      height: normalizedBox.height * box.height)
    guard rect.height > 0, rect.width > 0 else { return }
    // Satır kutusunun yüksekliğine göre punto — harf harf hizalama şart değil (bkz. dosya üstü
    // yorum), satır kutusu aramada/seçimde yeterli hizalama sağlıyor.
    let fontSize = max(4, rect.height * 0.85)
    let font =
      CTFontCreateUIFontForLanguage(.system, fontSize, nil)
      ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
    let attrs = [kCTFontAttributeName: font] as CFDictionary
    guard let attrString = CFAttributedStringCreate(nil, text as CFString, attrs) else { return }
    let line = CTLineCreateWithAttributedString(attrString)

    ctx.saveGState()
    ctx.setTextDrawingMode(.invisible)
    ctx.textPosition = CGPoint(x: rect.minX, y: rect.minY)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
  }
}

/// `SearchablePDFOperation`'a özgü hatalar — `OperationError`'a EKLENMEDİ (bkz. `QRError`/
/// `ExtractTextError` ile AYNI desen: işleme özgü hata kendi dosyasında).
public enum SearchablePDFError: Error, LocalizedError, Equatable {
  /// PDF çıktı akışı açılamadı.
  case generationFailed
  /// `OCRVerification.searchablePageContains` çıktıyı okuyamadı ya da beklenen metni bulamadı;
  /// çıktı silinir.
  case verificationFailed

  public var errorDescription: String? {
    switch self {
    case .generationFailed: return "Could not generate a searchable PDF"
    case .verificationFailed:
      return "Text was added but searchability could not be verified — output deleted"
    }
  }
}
