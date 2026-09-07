import CoreGraphics
import CoreText
import XCTest

@testable import PDFToolsCore

/// Tur 6'nın dört yeni işlemi için testler: Hızlı Görünüm İçin Hazırla, Onar, Görselleri Çıkar,
/// Metni Çıkar. Fixture'lar `Tur1Tests`'teki gibi CoreGraphics/CoreText ile PROGRAMATİK üretilir —
/// repoya gerçek/telifli dosya eklenmez.
final class Tur6Tests: XCTestCase {
  static let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  override class func setUp() {
    super.setUp()
    EngineLocator.extraDirectories = [repoRoot.appendingPathComponent("vendor/bin")]
  }

  private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdftools-tur6-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }

  // MARK: - Fixture üreticileri

  private static func makeMultiPageFixture(pageCount: Int, to url: URL) {
    try? FileManager.default.removeItem(at: url)
    var box = CGRect(x: 0, y: 0, width: 200, height: 200)
    guard let consumer = CGDataConsumer(url: url as CFURL) else { fatalError("CGDataConsumer") }
    guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
      fatalError("CGContext(consumer:mediaBox:auxiliaryInfo:)")
    }
    for i in 1...pageCount {
      context.beginPDFPage(nil)
      context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
      context.fill(box)
      context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
      context.fill(CGRect(x: Double((i * 17) % 150), y: 80, width: 40, height: 40))
      context.endPDFPage()
    }
    context.closePDF()
  }

  /// Klasik (akış) xref tablosunun ilk "N 00000 n" konum kaydını bir bayt kaydırarak dosyayı
  /// KASITLI olarak bozar — gerçek bir matbaa dosyasında rastlanan "bozuk xref" sınıfı hatayı taklit
  /// eder. Yöntem `qpdf --check` ile ölçülüp doğrulandı (bkz. `RepairOperation` yorumu): bu bozulma
  /// `qpdf --check`'i çıkış kodu 3 (uyarılı) ile "file is damaged" / "Attempting to reconstruct
  /// cross-reference table" uyarılarına düşürüyor; sade bir `qpdf giriş çıkış` yeniden yazması ise
  /// sorunu tamamen (çıkış kodu 0'a) gideriyor.
  private static func corruptFirstXrefOffset(at url: URL) throws {
    let data = try Data(contentsOf: url)
    guard let text = String(data: data, encoding: .isoLatin1) else {
      fatalError("PDF baytları ISO Latin-1 olarak çözülemedi")
    }
    guard let xrefRange = text.range(of: "\nxref\n") else { fatalError("xref bulunamadı") }
    guard
      let match = text.range(
        of: #"\d{10} 00000 n"#, options: .regularExpression,
        range: xrefRange.upperBound..<text.endIndex)
    else { fatalError("xref konum kaydı bulunamadı") }
    let digits = String(text[match].prefix(10))
    guard let value = Int(digits) else { fatalError("konum sayı değil") }
    var mutableText = text
    mutableText.replaceSubrange(match, with: String(format: "%010d", value + 1) + " 00000 n")
    guard let newData = mutableText.data(using: .isoLatin1) else {
      fatalError("değiştirilmiş metin ISO Latin-1'e kodlanamadı")
    }
    try newData.write(to: url)
  }

  private static func makeCheckerImage(width: Int, height: Int) -> CGImage {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let i = (y * width + x) * 4
        let isRed = ((x / 4) + (y / 4)) % 2 == 0
        pixels[i] = isRed ? 255 : 0
        pixels[i + 1] = 0
        pixels[i + 2] = isRed ? 0 : 255
        pixels[i + 3] = 255
      }
    }
    let cs = CGColorSpaceCreateDeviceRGB()
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: width * 4, space: cs,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
  }

  /// `imageSizes`'taki her boyutta bir CGImage'ı TEK sayfaya gömer (yalnız görsel, metin katmanı
  /// yok) — hem "Görselleri Çıkar" hem de "Metni Çıkar"ın taranmış-dosya yolunu test etmek için.
  private static func makeImageFixture(imageSizes: [(width: Int, height: Int)], to url: URL) {
    try? FileManager.default.removeItem(at: url)
    var box = CGRect(x: 0, y: 0, width: 200, height: 200)
    guard let consumer = CGDataConsumer(url: url as CFURL) else { fatalError("CGDataConsumer") }
    guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
      fatalError("CGContext")
    }
    context.beginPDFPage(nil)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(box)
    var x: CGFloat = 5
    for size in imageSizes {
      let image = makeCheckerImage(width: size.width, height: size.height)
      context.draw(image, in: CGRect(x: x, y: 10, width: 30, height: 30))
      x += 35
    }
    context.endPDFPage()
    context.closePDF()
  }

  /// Her girişteki metni ayrı bir sayfaya CoreText ile (gerçek glif) çizer — `page.string`'in
  /// çözebileceği bir metin katmanı üretmek için `context.fill` yeterli değil, gerçek font/glif
  /// gerekiyor (ölçülüp doğrulandı).
  private static func makeTextFixture(pages: [String], to url: URL) {
    try? FileManager.default.removeItem(at: url)
    var box = CGRect(x: 0, y: 0, width: 200, height: 200)
    guard let consumer = CGDataConsumer(url: url as CFURL) else { fatalError("CGDataConsumer") }
    guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
      fatalError("CGContext")
    }
    let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
    for text in pages {
      context.beginPDFPage(nil)
      context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
      context.fill(box)
      context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
      let attrs = [kCTFontAttributeName: font] as CFDictionary
      let attrString = CFAttributedStringCreate(nil, text as CFString, attrs)!
      let line = CTLineCreateWithAttributedString(attrString)
      context.textPosition = CGPoint(x: 10, y: 100)
      CTLineDraw(line, context)
      context.endPDFPage()
    }
    context.closePDF()
  }

  // MARK: - 1. Hızlı Görünüm İçin Hazırla

  func testLinearizePreservesPagesAndIsVerifiablyLinearized() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kitap.pdf")
    Self.makeMultiPageFixture(pageCount: 4, to: source)
    let info = PDFFileInfo.inspect(source)

    let outcome = try await LinearizeOperation().run(
      file: info, context: OperationContext(outputDirectory: dir)) { _ in }
    guard case .produced(let outputs, _) = outcome, let output = outputs.first else {
      return XCTFail("çıktı üretilmedi: \(outcome)")
    }
    XCTAssertEqual(output.lastPathComponent, "kitap_hizli.pdf")

    // Kanıt 1: sayfa sayısı korunmuş.
    guard let doc = CGPDFDocument(output as CFURL) else { return XCTFail("çıktı açılamadı") }
    XCTAssertEqual(doc.numberOfPages, 4)

    // Kanıt 2: qpdf --check GERÇEKTEN "lineerleştirilmiş" diyor (motora güvenilmiyor).
    guard let qpdf = EngineLocator.find("qpdf") else { return XCTFail("qpdf bulunamadı") }
    let diagnosis = try await LinearizeVerification.diagnose(qpdf: qpdf, url: output)
    XCTAssertTrue(diagnosis.isLinearized, "qpdf --check çıktısı: \(diagnosis.rawOutput)")

    // Karşıt kanıt: KAYNAK dosya (henüz lineerleştirilmemiş) aynı yöntemle "değil" dönmeli —
    // doğrulayıcının gerçekten ayırt ettiğinin kanıtı.
    let sourceDiagnosis = try await LinearizeVerification.diagnose(qpdf: qpdf, url: source)
    XCTAssertFalse(sourceDiagnosis.isLinearized)
  }

  // MARK: - 2. Onar

  func testRepairSkipsCleanFile() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("temiz.pdf")
    Self.makeMultiPageFixture(pageCount: 2, to: source)
    let outcome = try await RepairOperation().run(
      file: PDFFileInfo.inspect(source), context: OperationContext(outputDirectory: dir)) { _ in }
    XCTAssertEqual(outcome, .skipped(reason: "Dosyada sorun bulunamadı"))
  }

  func testRepairFixesCorruptFileAndReducesIssueCount() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("bozuk.pdf")
    Self.makeMultiPageFixture(pageCount: 3, to: source)
    try Self.corruptFirstXrefOffset(at: source)

    guard let qpdf = EngineLocator.find("qpdf") else { return XCTFail("qpdf bulunamadı") }
    let before = try await RepairVerification.diagnose(qpdf: qpdf, url: source)
    XCTAssertTrue(before.hasIssues, "fixture bozulmamış görünüyor — test önkoşulu sağlanmadı")

    let outcome = try await RepairOperation().run(
      file: PDFFileInfo.inspect(source), context: OperationContext(outputDirectory: dir)) { _ in }
    guard case .produced(let outputs, let note) = outcome, let output = outputs.first else {
      return XCTFail("çıktı üretilmedi: \(outcome)")
    }

    // Kanıt 1: sayfa sayısı korunmuş.
    guard let doc = CGPDFDocument(output as CFURL) else { return XCTFail("çıktı açılamadı") }
    XCTAssertEqual(doc.numberOfPages, 3)

    // Kanıt 2: onarım sonrası uyarı/hata GERÇEKTEN azalmış (idealde sıfıra inmiş).
    let after = try await RepairVerification.diagnose(qpdf: qpdf, url: output)
    XCTAssertFalse(after.hasIssues, "onarım sonrası hâlâ sorun var: \(after)")
    XCTAssertLessThan(after.issueLineCount, before.issueLineCount)
    XCTAssertNotNil(note)
  }

  // MARK: - 3. Görselleri Çıkar

  func testExtractImagesProducesExpectedOpenableNonEmptyFiles() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("gorselli.pdf")
    // Biri varsayılan eşiğin (10000 px alan) üstünde, biri altında — filtrelemenin GERÇEKTEN
    // çalıştığının kanıtı.
    Self.makeImageFixture(imageSizes: [(150, 100), (12, 12)], to: source)
    let info = PDFFileInfo.inspect(source)

    let defaultOutcome = try await ExtractImagesOperation().run(
      file: info, context: OperationContext(outputDirectory: dir)) { _ in }
    guard case .produced(let outputs, _) = defaultOutcome else {
      return XCTFail("çıktı üretilmedi: \(defaultOutcome)")
    }
    // Kanıt 1: yalnızca eşiği aşan görsel kaldı.
    XCTAssertEqual(outputs.count, 1, "varsayılan eşikte yalnız 1 görsel kalmalı: \(outputs)")
    XCTAssertTrue(
      outputs.allSatisfy { $0.deletingLastPathComponent().lastPathComponent == "gorselli_gorseller" })

    // Kanıt 2: her dosya GERÇEKTEN açılabilir bir görüntü ve BOŞ DEĞİL.
    for url in outputs {
      guard let result = ImageExportVerification.inspect(url) else {
        return XCTFail("görüntü okunamadı: \(url.lastPathComponent)")
      }
      XCTAssertGreaterThan(result.width * result.height, 0)
      XCTAssertGreaterThan(
        result.nonWhitePercent, 0, "\(url.lastPathComponent) boş görünüyor")
    }

    // Kanıt 3: minSize "0" verilince İKİ görsel de (küçük olan dahil) kalmalı.
    let allDir = dir.appendingPathComponent("all", isDirectory: true)
    try FileManager.default.createDirectory(at: allDir, withIntermediateDirectories: true)
    let allContext = OperationContext(
      outputDirectory: allDir, options: [ExtractImagesOperation.minSizeOptionID: "0"])
    let allOutcome = try await ExtractImagesOperation().run(file: info, context: allContext) { _ in }
    guard case .produced(let allOutputs, _) = allOutcome else {
      return XCTFail("çıktı üretilmedi: \(allOutcome)")
    }
    XCTAssertEqual(allOutputs.count, 2, "minSize=0 iken tüm görseller kalmalı: \(allOutputs)")
  }

  func testExtractImagesSkipsWhenNoEmbeddedImages() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("gorselsiz.pdf")
    Self.makeMultiPageFixture(pageCount: 2, to: source)
    let outcome = try await ExtractImagesOperation().run(
      file: PDFFileInfo.inspect(source), context: OperationContext(outputDirectory: dir)) { _ in }
    XCTAssertEqual(outcome, .skipped(reason: "Gömülü görsel bulunamadı"))
  }

  // MARK: - 4. Metni Çıkar

  func testExtractTextProducesCorrectContentWithPageSeparators() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("metinli.pdf")
    let page1 = "Merhaba sayfa bir icerik"
    let page2 = "Ikinci sayfa metni burada"
    let page3 = "Ucuncu ve son sayfa"
    Self.makeTextFixture(pages: [page1, page2, page3], to: source)
    let info = PDFFileInfo.inspect(source)

    let context = OperationContext(
      outputDirectory: dir, options: [ExtractTextOperation.layoutOptionID: "pages"])
    let outcome = try await ExtractTextOperation().run(file: info, context: context) { _ in }
    guard case .produced(let outputs, _) = outcome, let output = outputs.first else {
      return XCTFail("çıktı üretilmedi: \(outcome)")
    }
    XCTAssertEqual(output.lastPathComponent, "metinli.txt")

    let content = try String(contentsOf: output, encoding: .utf8)
    // Kanıt 1: her sayfanın GERÇEK içeriği çıktıda var.
    XCTAssertTrue(content.contains(page1))
    XCTAssertTrue(content.contains(page2))
    XCTAssertTrue(content.contains(page3))
    // Kanıt 2: sayfa ayraçları var.
    XCTAssertTrue(content.contains("--- sayfa 2 ---"))
    XCTAssertTrue(content.contains("--- sayfa 3 ---"))
    // Kanıt 3: sıralama doğru (1 önce, sonra 2, sonra 3) — yanlış sırayla birleştirme de
    // "içerik var" testini geçerdi, konum kontrolü gerçek kanıttır.
    guard let r1 = content.range(of: page1), let r2 = content.range(of: page2),
      let r3 = content.range(of: page3)
    else { return XCTFail("aralıklar bulunamadı") }
    XCTAssertTrue(r1.lowerBound < r2.lowerBound)
    XCTAssertTrue(r2.lowerBound < r3.lowerBound)
  }

  func testExtractTextSkipsScannedFileAndMentionsOCR() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("taranmis.pdf")
    Self.makeImageFixture(imageSizes: [(100, 100)], to: source)
    let outcome = try await ExtractTextOperation().run(
      file: PDFFileInfo.inspect(source), context: OperationContext(outputDirectory: dir)) { _ in }
    guard case .skipped(let reason) = outcome else {
      return XCTFail("atlanmadı: \(outcome)")
    }
    XCTAssertTrue(reason.localizedCaseInsensitiveContains("OCR"), "mesaj OCR'a işaret etmiyor: \(reason)")
  }
}
