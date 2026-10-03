import CoreGraphics
import CoreText
import Foundation
import Vision

/// Taranmış bir PDF'in ÜSTÜNE görünmez bir metin katmanı ekler: görüntü aynen kalır, ama sayfa
/// artık aranabilir/seçilebilir. Harici model YOK, API anahtarı YOK — Apple Vision.
///
/// İKİ KİP (2026-10-03, spec `.claude/docs/aranabilir-katman-spec.md`):
///
/// · `overlay` (VARSAYILAN, kayıpsız): `OCRTextLayer` yalnız görünmez metin içeren bir katman
///   PDF'i yazar, `qpdf <kaynak> --overlay <katman> -- <çıktı>` onu kaynağın üstüne bindirir.
///   Kaynak sayfa hiç yeniden ÇİZİLMEZ: görüntü baytları birebir (pdfimages sha256), 36 dpi render
///   `cmp` ile birebir, font/renk/piksel değişimi sıfır (gerçek kitap sayfalarında ölçüldü).
///   `RewriteOutput.finish` bu kipte KULLANILMAZ — "redrawing changed the file" cümlesi yalan
///   olurdu; kendi altı kapısı var (bkz. `verifyOverlay`).
///
/// · `redraw` (eski yol): her sayfa CoreGraphics ile yeni PDF'e kopyalanır (`QRAddOperation.
///   writeOutput` deseni), satırlar `Tr 3` ile görünmez çizilir, `RewriteOutput.finish` xref'i
///   onarıp kalan hasarı sonuç satırında SÖYLER. Yalnız AÇIKÇA seçilince çalışır.
///
/// qpdf bulunamazsa `overlay` FIRLATIR (`SearchablePDFError.qpdfMissing`), `redraw`'a DÜŞMEZ
/// (2026-10-03 saha arızası): paket dışı release ikilisi qpdf'i bulamadı, 64 sayfalık kitap "✓"
/// ile kayıplı üretildi ve uyarı yalnız logda kaldı. Kayıpsız söz verip kayıplı üretmek sessiz
/// arızadır — fail-closed.
public struct SearchablePDFOperation: PDFOperation {
  public static let identifier = "searchablepdf"
  public let id = SearchablePDFOperation.identifier
  public let title = "Make Searchable"
  public let subtitle = "Adds an invisible text layer to the scanned PDF so it becomes searchable"
  public let systemImage = "doc.text.magnifyingglass"
  public let actionTitle = "Make Searchable"
  public let outputSuffix = "_searchable"
  public var outputSuffixes: [String] { [outputSuffix] }

  public static let modeOptionID = "mode"
  public static let overlayMode = "overlay"
  public static let redrawMode = "redraw"
  public static let modeChoices: [(value: String, label: String)] = [
    (overlayMode, "Lossless overlay (pages kept byte-for-byte)"),
    (redrawMode, "Redraw pages (legacy)"),
  ]

  static let noTextReason = "No text recognized — pages may be blank or too low quality to read"

  /// Piksel kapısı eşiği: kanal başına ortalama mutlak fark ≤ 0,5/255.
  static let maxMeanPixelDifference = 0.5 / 255
  /// Piksel kapısında render'ın uzun kenarı (px).
  static let pixelCheckLongSide: CGFloat = 600

  /// qpdf'i bulan fonksiyon — testler "qpdf yok" durumunu buradan kurar (CI'da Homebrew qpdf'i
  /// `EngineLocator` aramasından çıkarmanın yolu yok).
  let locateQPDF: @Sendable () -> URL?
  /// YALNIZ TESTLER: bindirilmiş ara çıktı (`output`) kapılardan ÖNCE bozulabilsin diye kanca —
  /// kapıların gerçekten reddettiği ve reddedilen çıktının görünür ada sızmadığı uçtan uca
  /// sınanır (inceleme 2026-10-03: kapılar kapatılınca hiçbir test kırmızı vermiyordu).
  let afterOverlay: (@Sendable (_ output: URL, _ source: URL) async throws -> Void)?

  /// Var olan metin katmanına ikinci bir katman eklenmez (arama sonuçları çiftlenirdi).
  public static let existingTextLayerReason = "already has a text layer — would add a second one"

  public init() {
    self.locateQPDF = { EngineLocator.find("qpdf") }
    self.afterOverlay = nil
  }

  init(
    locateQPDF: @escaping @Sendable () -> URL? = { EngineLocator.find("qpdf") },
    afterOverlay: (@Sendable (_ output: URL, _ source: URL) async throws -> Void)? = nil
  ) {
    self.locateQPDF = locateQPDF
    self.afterOverlay = afterOverlay
  }

  public var options: [OperationOption] {
    [
      OperationOption(
        id: OCROperation.languageOptionID, label: "Language", choices: OCROperation.languageChoices,
        defaultValue: "tr"),
      OperationOption(
        id: OCROperation.dpiOptionID, label: "Resolution", choices: OCROperation.dpiChoices,
        defaultValue: OCROperation.defaultDPIValue),
      OperationOption(
        id: Self.modeOptionID, label: "Mode", choices: Self.modeChoices,
        defaultValue: Self.overlayMode),
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
    // Kapı f'nin girdisi: kaynağın (boyut, mtime) damgası İŞLEM BAŞINDA alınır.
    let sourceStamp = Self.fileStamp(of: file.url)
    guard let document = CGPDFDocument(file.url as CFURL), document.isUnlocked else {
      throw OperationError.unreadable
    }
    let total = document.numberOfPages
    guard total > 0 else { return .skipped(reason: "No pages") }
    // Çift katman önlenir: metni zaten aranabilir dosyaya ikinci görünmez katman eklemek arama
    // sonuçlarını ve kopyalanan metni çiftler (inceleme 2026-10-03).
    if OCRVerification.hasExistingTextLayer(at: file.url) {
      return .skipped(reason: Self.existingTextLayerReason)
    }

    let languageKey = context.options[OCROperation.languageOptionID] ?? "tr"
    let languages =
      OCROperation.recognitionLanguages[languageKey] ?? OCROperation.recognitionLanguages["tr"]!
    let resolution = OCROperation.resolution(from: context.options[OCROperation.dpiOptionID])
    let mode = context.options[Self.modeOptionID] ?? Self.overlayMode
    guard mode == Self.overlayMode || mode == Self.redrawMode else {
      throw SearchablePDFError.unknownMode(mode)
    }

    let output = OutputNaming.uniqueURL(
      for: file.url, suffix: outputSuffix, in: context.outputDirectory)

    if mode == Self.redrawMode {
      return try await runRedraw(
        file: file, document: document, total: total, languageKey: languageKey,
        languages: languages, resolution: resolution, output: output, progress: progress)
    }
    // FAIL-CLOSED (bkz. dosya üstü): kayıpsız kip qpdf'siz kayıplı yola DÜŞMEZ.
    guard let qpdf = locateQPDF() else { throw SearchablePDFError.qpdfMissing }

    // GÜVENLİK: katmanı CoreGraphics, çıktıyı qpdf (alt süreç) KENDİSİ oluşturuyor —
    // `TempArtifact.withPrivateDirectory` (bkz. o tipin gerekçesi). Bir kapı düşerse fırlatılır ve
    // dizin `defer` ile İÇERİĞİYLE silinir: yarım çıktı asla görünür ada taşınmaz.
    return try await TempArtifact.withPrivateDirectory(
      in: output.deletingLastPathComponent()
    ) { tempDir in
      // 1. Katman (ilerleme 0 → 0,85).
      let layer = tempDir.appendingPathComponent("layer.pdf")
      let result = try OCRTextLayer.write(
        document: document, to: layer, languages: languages, resolution: resolution,
        progress: { progress($0 * 0.85) })
      guard result.totalWords > 0 else { return .skipped(reason: Self.noTextReason) }

      // 2. Katman sayfa sayısı (eksik sayfa kapısı).
      try Self.checkLayerPageCount(layer: layer, expected: total)

      // 3. Döndürülmüş sayfa telafisi (bkz. `OCRTextLayer.rotationArguments`, ölçüm orada).
      let rotation = try OCRTextLayer.rotationArguments(for: document)
      var placedLayer = layer
      if !rotation.isEmpty {
        let rotated = tempDir.appendingPathComponent("layer-rotated.pdf")
        let rotateRun = try await ProcessRunner.run(
          qpdf,
          arguments: [QPDFArgument.path(for: layer)] + rotation + [
            "--", QPDFArgument.path(for: rotated),
          ])
        guard rotateRun.status == 0 || rotateRun.status == 3,
          FileManager.default.fileExists(atPath: rotated.path)
        else { throw SearchablePDFError.overlayFailed(rotateRun.stderr) }
        try Self.checkLayerPageCount(layer: rotated, expected: total)
        placedLayer = rotated
      }

      // 4. Bindirme. `--overlay`'in `--` sonlandırıcısı qpdf sözdiziminin parçası (katman
      // dosyasının seçeneklerini bitirir); yollar yine `QPDFArgument.path` ile korunur.
      let partial = tempDir.appendingPathComponent("output.pdf")
      let overlayRun = try await ProcessRunner.run(
        qpdf,
        arguments: [
          QPDFArgument.path(for: file.url), "--overlay", QPDFArgument.path(for: placedLayer), "--",
          QPDFArgument.path(for: partial),
        ])
      guard overlayRun.status == 0 || overlayRun.status == 3,
        FileManager.default.fileExists(atPath: partial.path)
      else { throw SearchablePDFError.overlayFailed(overlayRun.stderr) }
      progress(0.9)
      if let afterOverlay { try await afterOverlay(partial, file.url) }

      // 5. Kapılar (sırayla; biri düşerse fırlatır, çıktı özel dizinle birlikte silinir).
      let gateWarnings = try await Self.verifyOverlay(
        source: file.url, output: partial, result: result, qpdf: qpdf, sourceStamp: sourceStamp)

      // 6. Teslim.
      try FileManager.default.moveItem(at: partial, to: output)
      progress(1)
      return .produced(
        urls: [output],
        note: Self.overlayNote(
          result: result, total: total, languageKey: languageKey, warnings: gateWarnings))
    }
  }

  // MARK: - overlay kapıları

  /// Katman PDF'inin sayfa sayısı kaynakla aynı mı — değilse `layerPageCount` fırlatır.
  static func checkLayerPageCount(layer: URL, expected: Int) throws {
    guard let document = CGPDFDocument(layer as CFURL) else {
      throw SearchablePDFError.layerPageCount(expected: expected, actual: 0)
    }
    guard document.numberOfPages == expected else {
      throw SearchablePDFError.layerPageCount(expected: expected, actual: document.numberOfPages)
    }
  }

  /// Spec §2.5'in altı kapısı, SIRAYLA: (a) yapı, (b) sayfa sayısı, (c) görüntü kimliği, (d) metin,
  /// (e) piksel sadakati, (f) kaynak dokunulmamış.
  static func verifyOverlay(
    source: URL, output: URL, result: OCRTextLayer.Result, qpdf: URL, sourceStamp: FileStamp?
  ) async throws -> [String] {
    // a. Yapı. Paketli qpdf'in "Wrong JPEG library version" uyarısı `PDFStructureCheck.parse`
    // tarafından hata SAYILMAZ (ikilinin kusuru, dosyanın değil — gerçek kitap sayfasında ölçüldü).
    let structure = try await PDFStructureCheck.inspect(output, qpdf: qpdf)
    guard structure.isSound else {
      throw OperationError.outputStructureBroken(structure.summary)
    }

    // b. Sayfa sayısı — iki tarafı da qpdf ölçer.
    let sourcePages = await RewriteOutput.pageCount(of: source, qpdf: qpdf)
    let outputPages = await RewriteOutput.pageCount(of: output, qpdf: qpdf)
    guard let sourcePages, let outputPages else {
      throw OperationError.pageIntegrityUnverifiable("qpdf could not count the pages")
    }
    guard sourcePages == outputPages else {
      throw SearchablePDFError.pageCountChanged(before: sourcePages, after: outputPages)
    }

    // c. Görüntü kimliği (süreç içi, alt süreç yok).
    // Okunamayan akış iki tarafta da "okunamadı" görünse bile EŞİTLİK sayılmaz — ölçülemedi.
    let sourceImages: [[String]]?
    let outputImages: [[String]]?
    do {
      sourceImages = try PDFImageIdentity.pageImageHashes(at: source)
      outputImages = try PDFImageIdentity.pageImageHashes(at: output)
    } catch let error as PDFImageIdentity.UnreadableImage {
      throw SearchablePDFError.gateUnverifiable(error.errorDescription ?? "image unreadable")
    }
    guard let sourceImages, let outputImages else {
      throw SearchablePDFError.gateUnverifiable("image streams could not be read")
    }
    let changed = PDFImageIdentity.changedPages(source: sourceImages, output: outputImages)
    guard changed.isEmpty else { throw SearchablePDFError.imagesChanged(pages: changed) }

    // d. Metin (bkz. `textGateSamples`): örnek sayfalarda metin VAR mı ve OCR'ın bulduğu
    // KONUMDA mı (PDFKit seçimi). Katman kayarsa metin sayfada durur ama yerinde olmaz.
    var warnings: [String] = []
    let samples = textGateSamples(result)
    if samples.isEmpty {
      // Uygun gövde satırı yok (tüm sayfalar kapak/dekoratif): konum ölçülemedi — bu SÖYLENİR;
      // metin varlığı yine zorunlu.
      for stats in topScoredPages(result) {
        let text = OCRVerification.pageText(pdfAt: output, pageIndex: stats.pageIndex) ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw SearchablePDFError.textNotFound(page: stats.pageIndex)
        }
      }
      warnings.append(noBodyTextNote)
    }
    for stats in samples {
      guard let text = stats.sampleText, let rect = stats.sampleRect else { continue }
      let pageText = OCRVerification.pageText(pdfAt: output, pageIndex: stats.pageIndex) ?? ""
      guard OCRVerification.coverage(of: text, in: pageText) >= minTextCoverage else {
        throw SearchablePDFError.textNotFound(page: stats.pageIndex)
      }
      // Pay = bir satır yüksekliği: daha dar payda PDFKit satır sonundaki noktayı seçmedi
      // (gerçek kitap sayfasında ölçüldü — "…bulunmalıdır." → "…bulunmalıdır").
      let pad = min(rect.width, rect.height)
      let selected =
        OCRVerification.selectionText(
          pdfAt: output, pageIndex: stats.pageIndex, rect: rect.insetBy(dx: -pad, dy: -pad))
        ?? ""
      guard OCRVerification.coverage(of: text, in: selected) >= minTextCoverage else {
        throw SearchablePDFError.textMisplaced(page: stats.pageIndex)
      }
    }

    // e. Piksel sadakati: ilk/orta/son sayfa, uzun kenar ≈ 600 px.
    guard let sourceDoc = CGPDFDocument(source as CFURL),
      let outputDoc = CGPDFDocument(output as CFURL)
    else { throw SearchablePDFError.gateUnverifiable("pages could not be rendered") }
    for pageIndex in spread(Array(1...max(1, sourcePages))) {
      guard let sourcePage = sourceDoc.page(at: pageIndex),
        let outputPage = outputDoc.page(at: pageIndex)
      else { throw SearchablePDFError.gateUnverifiable("page \(pageIndex) could not be opened") }
      let box = sourcePage.getBoxRect(.mediaBox)
      let longSide = max(box.width, box.height)
      let dpi = longSide > 0 ? pixelCheckLongSide * 72 / longSide : 72
      guard
        let diff = OCRVerification.averagePixelDifference(
          pageA: sourcePage, pageB: outputPage, dpi: dpi)
      else {
        throw SearchablePDFError.gateUnverifiable("page \(pageIndex) could not be rendered")
      }
      guard diff <= maxMeanPixelDifference else {
        throw SearchablePDFError.visualChange(page: pageIndex, meanDiff: diff)
      }
    }

    // f. Kaynak dokunulmamış.
    guard let sourceStamp, fileStamp(of: source) == sourceStamp else {
      throw SearchablePDFError.sourceModified
    }
    return warnings
  }

  /// Kapı d'nin kapsama eşiği (ardışık eşleşen karakter / örnek satır).
  static let minTextCoverage = 0.8
  /// Konum ölçülemediğinde sonuç notuna düşen cümle (sessiz geçiş YOK).
  public static let noBodyTextNote =
    "text position could not be verified (no suitable body text)"

  /// Metni olan sayfalar, (kelime × ortalama güven) puanına göre azalan; en çok `limit` tane.
  /// Kapak/arka kapak (az, düşük güvenli, dekoratif metin) doğal olarak geride kalır.
  static func topScoredPages(
    _ result: OCRTextLayer.Result, limit: Int = 3
  ) -> [OCRTextLayer.PageStats] {
    Array(rankedPages(result).prefix(limit))
  }

  /// Kapı d örnek sayfaları (saha arızası 2026-10-03: ilk/orta/son seçimi 338 sayfalık kitabın
  /// arka kapağına — harf aralıklı altbilgiye — düştü ve yanlış ret verdi): puan sırasıyla,
  /// uygun gövde satırı OLAN ilk 3 sayfa; olmayan sayfa atlanır, sıradakine geçilir.
  static func textGateSamples(
    _ result: OCRTextLayer.Result, limit: Int = 3
  ) -> [OCRTextLayer.PageStats] {
    Array(rankedPages(result).filter { $0.sampleText != nil && $0.sampleRect != nil }.prefix(limit))
  }

  private static func rankedPages(_ result: OCRTextLayer.Result) -> [OCRTextLayer.PageStats] {
    func score(_ stats: OCRTextLayer.PageStats) -> Double {
      Double(stats.words) * stats.meanConfidence
    }
    return result.pages.filter { $0.words > 0 }.sorted {
      score($0) != score($1) ? score($0) > score($1) : $0.pageIndex < $1.pageIndex
    }
  }

  /// İlk, orta ve son öğe (tekrarsız, sırası korunarak).
  static func spread<T>(_ items: [T]) -> [T] {
    guard !items.isEmpty else { return [] }
    var indices: [Int] = []
    for index in [0, items.count / 2, items.count - 1] where !indices.contains(index) {
      indices.append(index)
    }
    return indices.map { items[$0] }
  }

  /// Kaynağın dokunulmadığını gösteren damga: bayt boyutu + değişiklik zamanı.
  struct FileStamp: Equatable {
    let size: UInt64
    let modified: Date
  }

  static func fileStamp(of url: URL) -> FileStamp? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let size = attributes[.size] as? NSNumber,
      let modified = attributes[.modificationDate] as? Date
    else { return nil }
    return FileStamp(size: size.uint64Value, modified: modified)
  }

  /// `"lossless overlay · N words on M/T pages · mean confidence 0.99"` + metinsiz sayfalar +
  /// Türkçe uyarısı.
  static func overlayNote(
    result: OCRTextLayer.Result, total: Int, languageKey: String, warnings: [String] = []
  ) -> String {
    let pagesWithText = result.pages.filter { $0.words > 0 }.count
    let weighted = result.pages.reduce(0.0) { $0 + $1.meanConfidence * Double($1.words) }
    let mean = result.totalWords > 0 ? weighted / Double(result.totalWords) : 0
    var parts = [
      "lossless overlay · \(result.totalWords) words on \(pagesWithText)/\(total) pages · "
        + String(format: "mean confidence %.2f", mean)
    ]
    let blank = result.pagesWithoutText
    if !blank.isEmpty {
      let shown = blank.prefix(10).map(String.init).joined(separator: ", ")
      let suffix = blank.count > 10 ? ", …" : ""
      parts.append("\(blank.count) pages had no recognizable text: \(shown)\(suffix)")
    }
    if let warning = turkishWarning(
      languageKey: languageKey, sawDiacritic: result.sawTurkishDiacritic)
    {
      parts.append(warning)
    }
    parts.append(contentsOf: warnings)
    return parts.joined(separator: " · ")
  }

  /// İKİ BAĞIMSIZ sinyal — bkz. `OCRVerification` dosya üstü CI ölçümü (GitHub macos-15
  /// runner, 2026-09-08): bu makinede Vision'ın tr-TR'ye sessizce düşmediğinden emin olunamıyorsa
  /// YA DA gerçek tanınan metinde hiç Türkçe aksanlı harf yoksa, eklenen metin GÖRÜNMEZ katmanda
  /// sessizce bozuk kalabilir — kullanıcı bunu göremez (metin zaten görünmez).
  static func turkishWarning(languageKey: String, sawDiacritic: Bool) -> String? {
    guard languageKey == "tr" || languageKey == "auto" else { return nil }
    let missingFromSupportedList = !OCRVerification.allLanguagesSupported(
      ["tr-TR"], level: .accurate)
    return missingFromSupportedList || !sawDiacritic ? OCROperation.turkishSupportWarning : nil
  }

  // MARK: - redraw (eski yol)

  private func runRedraw(
    file: PDFFileInfo, document: CGPDFDocument, total: Int, languageKey: String,
    languages: [String], resolution: OCRTextLayer.Resolution, output: URL,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> OperationOutcome {
    let fm = FileManager.default
    // GÜVENLİK: `writeOutput` bir `CGDataConsumer(url:)` üzerinden CoreGraphics'in KENDİSİ
    // tarafından oluşturulan bir dosyaya yazıyor — `TempArtifact.withPrivateDirectory` kullanılıyor
    // (bkz. o tipin gerekçesi).
    return try await TempArtifact.withPrivateDirectory(
      in: output.deletingLastPathComponent()
    ) { tempDir in
      let partial = tempDir.appendingPathComponent("output.pdf")
      let (samples, sawTurkishDiacritic) = try Self.writeOutput(
        document: document, total: total, languages: languages, resolution: resolution,
        to: partial, progress: progress)

      guard let firstSample = samples.first else {
        return .skipped(reason: Self.noTextReason)
      }

      // Kanıt: görünmez metin GERÇEKTEN seçilebilir/aranabilir mi (bkz. dosya üstü yorum).
      guard
        OCRVerification.searchablePageContains(
          pdfAt: partial, pageIndex: firstSample.pageIndex,
          expectedSubstring: firstSample.sampleText)
      else {
        throw SearchablePDFError.verificationFailed
      }

      // YENİDEN ÇİZMENİN ORTAK SON ADIMI (bkz. `RewriteOutput` gerekçesi): bu kip sayfayı
      // CoreGraphics ile yeniden çiziyor; ölçüldüğünde çıktının xref'i kırılıyor (gerçek bir
      // matbaa dosyasında 64 nesne "offset 0"), sürüm düşüyor ve XMP üstverisi siliniyor. Onarım +
      // yapı kapısı burada; kalan hasar sonuç satırında SÖYLENİYOR, sessizce yutulmuyor.
      let rewrite = try await RewriteOutput.finish(output: partial, source: file.url)

      try fm.moveItem(at: partial, to: output)
      progress(1)

      // Türkçe uyarısı ve yeniden çizme hasarı birlikte bildirilir — biri diğerini bastırmaz.
      let warning = Self.turkishWarning(languageKey: languageKey, sawDiacritic: sawTurkishDiacritic)
      let notes = [warning, rewrite.note].compactMap { $0 }
      return .produced(urls: [output], note: notes.isEmpty ? nil : notes.joined(separator: " · "))
    }
  }

  /// Kaynağın TÜM sayfalarını (kendi MediaBox'larıyla) yeni bir PDF'e kopyalar, her sayfada Vision
  /// ile metni tanır ve görünmez biçimde üstüne çizer. Her sayfa için ilk tanınan (boş olmayan)
  /// satırı `samples`'a ekler — `run()`'daki doğrulama gate'i bunu kullanır (görev tanımındaki
  /// "OCR'ın bulduğu belirgin bir kelimenin ORADA olduğunu doğrula" kanıtının girdisi).
  /// `sawTurkishDiacritic`: TÜM sayfalardaki TÜM satırlarda en az bir Türkçe aksanlı harf (ş/ğ/İ/
  /// ı/Ş/Ğ) görüldü mü — Türkçe dil desteği bozukluğunun ikinci sinyali (bkz. `run()`), metni
  /// bellekte biriktirmeden tek bir bayrakla izlenir.
  private static func writeOutput(
    document: CGPDFDocument, total: Int, languages: [String], resolution: OCRTextLayer.Resolution,
    to url: URL,
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
      // doğrulanmış desen (bkz. o dosyadaki yorum): farklı sayfa boyutları da aslına sadık
      // kopyalanır.
      var box = page.getBoxRect(.mediaBox)
      let pageInfo: [CFString: Any] = [
        kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
      ]
      ctx.beginPDFPage(pageInfo as CFDictionary)
      ctx.drawPDFPage(page)

      // Döngü içinde: tanıma sırasındaki render bitmap'i yalnızca bu iterasyon boyunca yaşar —
      // aynı anda TEK sayfalık görüntü bellekte (bkz. `ImageExportOperation` ile AYNI gerekçe).
      let lines = try OCRVerification.recognizeText(
        onPage: page, scale: OCRTextLayer.renderScale(for: page, resolution: resolution),
        languages: languages, level: .accurate)
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
  /// `mode` seçeneği tanınmayan bir değer taşıyor.
  case unknownMode(String)
  /// Katman yazılırken kaynak sayfa açılamadı (sessiz atlama YASAK — eksik sayfa kapısı).
  case pageUnreadable(page: Int)
  /// Katman PDF'inin sayfa sayısı kaynakla uyuşmuyor.
  case layerPageCount(expected: Int, actual: Int)
  /// `qpdf --overlay` (ya da katman döndürme) başarısız oldu / çıktı yazmadı.
  case overlayFailed(String)
  /// Bindirilmiş çıktının sayfa sayısı kaynaktan farklı.
  case pageCountChanged(before: Int, after: Int)
  /// Görüntü akışlarının baytları kaynakla çıktıda farklı olan sayfalar (1 tabanlı).
  case imagesChanged(pages: [Int])
  /// Tanınan örnek metin çıktının bu sayfasında PDFKit ile bulunamadı.
  case textNotFound(page: Int)
  /// Örnek metin sayfada var ama OCR'ın bulduğu konumda seçilmiyor (katman kaymış).
  case textMisplaced(page: Int)
  /// Çıktı kaynaktan görsel olarak farklı (kanal başına ortalama fark, 0…1).
  case visualChange(page: Int, meanDiff: Double)
  /// Kaynak dosya işlem sırasında değişti (boyut ya da değişiklik zamanı).
  case sourceModified
  /// Bir kapı ölçüm yapamadı — "ölçemedim" ile "sorun yok" aynı şey değil, fırlatılır.
  case gateUnverifiable(String)
  /// `overlay` kipi qpdf'i bulamadı — kayıplı yola DÜŞÜLMEZ (fail-closed).
  case qpdfMissing

  public var errorDescription: String? {
    switch self {
    case .generationFailed: return "Could not generate a searchable PDF"
    case .verificationFailed:
      return "Text was added but searchability could not be verified — output deleted"
    case .unknownMode(let mode):
      return "Unknown mode \"\(mode)\" — use overlay or redraw"
    case .pageUnreadable(let page):
      return "Page \(page) could not be opened — no output was written"
    case .layerPageCount(let expected, let actual):
      return "Text layer has \(actual) pages instead of \(expected) — output deleted"
    case .overlayFailed(let detail):
      let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
      return "qpdf could not place the text layer" + (trimmed.isEmpty ? "" : " (\(trimmed))")
    case .pageCountChanged(let before, let after):
      return "Output page count differs from the source (\(before) → \(after)) — output deleted"
    case .imagesChanged(let pages):
      let list = pages.prefix(10).map(String.init).joined(separator: ", ")
      return "Images changed on page(s) \(list) — output deleted"
    case .textMisplaced(let page):
      return "Text layer on page \(page) is not aligned with the printed text — output deleted"
    case .textNotFound(let page):
      return "Recognized text could not be found on page \(page) of the output — output deleted"
    case .visualChange(let page, let meanDiff):
      return "Page \(page) looks different from the source "
        + String(format: "(mean difference %.2f/255)", meanDiff * 255) + " — output deleted"
    case .sourceModified:
      return "The source file changed while it was being processed — output deleted"
    case .gateUnverifiable(let detail):
      return "Output could not be verified — \(detail); output deleted"
    case .qpdfMissing:
      return "Lossless overlay needs the bundled qpdf engine — run packaging/build-engines.sh, "
        + "or choose Redraw mode explicitly (lossy)"
    }
  }
}
