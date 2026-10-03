import CoreGraphics
import CoreText
import CryptoKit
import PDFKit
import Vision
import XCTest

@testable import PDFToolsCore

/// "Aranabilir Yap"ın kayıpsız `overlay` kipi (spec `.claude/docs/aranabilir-katman-spec.md` §4).
///
/// Fikstür testte üretilir (telifli dosya repoya girmez): 2 sayfalık, sayfa başına TEK görüntü
/// içeren PDF; sayfalar FARKLI MediaBox (1200×1600 ve 1000×1400 pt, 1 pt = 1 px). Metin önce bir
/// bitmap'e büyük puntoyla çizilir, bitmap `CGContext.draw(cgImage, in:)` ile gömülür — sayfada
/// vektör metin YOK. Her kelime AYRI çizilir; böylece basılı kelimenin sayfadaki dikdörtgeni
/// bilinir (hizalama testi bunun üstüne kurulu).
///
/// CI'da Vision tr-TR yok (bkz. `Tur9Tests` CI notu): Türkçe metin yalnız
/// `OCRVerification.allLanguagesSupported(["tr-TR"])` ise kullanılır, değilse İngilizce metinle
/// AYNI testler koşar (`XCTSkip` YOK).
final class SearchableOverlayTests: XCTestCase {
  struct UnexpectedOutcome: Error {}

  static let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  override func setUp() {
    super.setUp()
    EngineLocator.extraDirectories = [Self.repoRoot.appendingPathComponent("vendor/bin")]
  }

  private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdftools-overlay-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }

  // MARK: - Fikstür

  /// Ortama göre dil ve kelimeler.
  struct Script {
    let languageKey: String
    /// Sayfa başına kelimeler (her kelime ayrı satırda, büyük puntoyla).
    let pages: [[String]]
    /// Hizalama testinin kelimesi (1. sayfanın ilk kelimesi).
    var anchorWord: String { pages[0][0] }
  }

  static let turkishSupported = OCRVerification.allLanguagesSupported(
    ["tr-TR"], level: .accurate)

  static var script: Script {
    turkishSupported
      ? Script(languageKey: "tr", pages: [["MERHABA", "KİTAP", "SAYFASI"], ["DÜNYA", "OKUL"]])
      : Script(languageKey: "en", pages: [["HELLO", "BOOK", "PAGE"], ["WORLD", "SCHOOL"]])
  }

  static let pageSizes = [CGSize(width: 1200, height: 1600), CGSize(width: 1000, height: 1400)]
  static let fontSize: CGFloat = 110

  /// Fikstürü yazar; sayfa başına her kelimenin sayfa uzayındaki (orijin SOL-ALT) dikdörtgenini
  /// döner.
  @discardableResult
  static func makeFixture(to url: URL) -> [[String: CGRect]] {
    var rects: [[String: CGRect]] = []
    var dummy = CGRect(x: 0, y: 0, width: 1, height: 1)
    guard let consumer = CGDataConsumer(url: url as CFURL),
      let pdf = CGContext(consumer: consumer, mediaBox: &dummy, nil)
    else { fatalError("PDF bağlamı") }
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
    for (pageIndex, size) in pageSizes.enumerated() {
      let width = Int(size.width)
      let height = Int(size.height)
      guard
        let bitmap = CGContext(
          data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      else { fatalError("bitmap") }
      bitmap.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
      bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
      bitmap.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
      var pageRects: [String: CGRect] = [:]
      var baseline = size.height - 250
      for word in script.pages[pageIndex] {
        let attrs = [kCTFontAttributeName: font] as CFDictionary
        guard let string = CFAttributedStringCreate(nil, word as CFString, attrs) else {
          fatalError("metin")
        }
        let line = CTLineCreateWithAttributedString(string)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let origin = CGPoint(x: 120, y: baseline)
        bitmap.textPosition = origin
        CTLineDraw(line, bitmap)
        pageRects[word] = CGRect(
          x: origin.x, y: origin.y - descent, width: lineWidth, height: ascent + descent)
        baseline -= 300
      }
      rects.append(pageRects)
      guard let image = bitmap.makeImage() else { fatalError("görüntü") }
      var box = CGRect(origin: .zero, size: size)
      let info: [CFString: Any] = [
        kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
      ]
      pdf.beginPDFPage(info as CFDictionary)
      pdf.draw(image, in: box)
      pdf.endPDFPage()
    }
    pdf.closePDF()
    return rects
  }

  private func qpdf() throws -> URL {
    try XCTUnwrap(
      EngineLocator.find("qpdf"), "qpdf bulunamadı — packaging/build-engines.sh ya da brew")
  }

  private func runOverlay(
    _ source: URL, in dir: URL, extra: [String: String] = [:]
  ) async throws -> (url: URL, note: String?) {
    var options = [OCROperation.languageOptionID: Self.script.languageKey]
    options.merge(extra) { _, new in new }
    let outcome = try await SearchablePDFOperation().run(
      file: PDFFileInfo.inspect(source),
      context: OperationContext(outputDirectory: dir, options: options)
    ) { _ in }
    guard case .produced(let urls, let note) = outcome, let url = urls.first else {
      XCTFail("beklenmeyen sonuç: \(outcome)")
      throw UnexpectedOutcome()
    }
    return (url, note)
  }

  private func sha256(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
  }

  /// Aksan farkına dayanıklı kıyas (CI'da tr-TR yokken aksanlar düşebilir — `Tur9Tests` deseni).
  private func normalized(_ text: String) -> String {
    let pairs: [(String, String)] = [
      ("İ", "i"), ("I", "i"), ("ı", "i"), ("Ş", "s"), ("ş", "s"), ("Ğ", "g"), ("ğ", "g"),
      ("Ü", "u"), ("ü", "u"), ("Ö", "o"), ("ö", "o"), ("Ç", "c"), ("ç", "c"),
    ]
    var result = text
    for (from, to) in pairs { result = result.replacingOccurrences(of: from, with: to) }
    return result.lowercased().filter { !$0.isWhitespace }
  }

  // MARK: - (1) sayfa sayısı + MediaBox korunmuş

  func testOverlayKeepsPageCountAndEachMediaBox() async throws {
    _ = try qpdf()
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kaynak.pdf")
    Self.makeFixture(to: source)
    let (output, note) = try await runOverlay(source, in: dir)
    XCTAssertTrue(note?.contains("lossless overlay") == true, "overlay notu yok: \(note ?? "-")")

    let doc = try XCTUnwrap(CGPDFDocument(output as CFURL))
    XCTAssertEqual(doc.numberOfPages, 2)
    for (index, size) in Self.pageSizes.enumerated() {
      let box = try XCTUnwrap(doc.page(at: index + 1)).getBoxRect(.mediaBox)
      XCTAssertEqual(box, CGRect(origin: .zero, size: size), "sayfa \(index + 1) MediaBox")
    }
  }

  // MARK: - (2) PDFKit her sayfada metni buluyor

  func testPDFKitFindsTextOnEveryPage() async throws {
    _ = try qpdf()
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kaynak.pdf")
    Self.makeFixture(to: source)
    XCTAssertFalse(OCRVerification.hasExistingTextLayer(at: source), "fikstürde metin VAR")
    let (output, _) = try await runOverlay(source, in: dir)

    let doc = try XCTUnwrap(PDFDocument(url: output))
    for (index, words) in Self.script.pages.enumerated() {
      let text = doc.page(at: index)?.string ?? ""
      for word in words {
        XCTAssertTrue(
          normalized(text).contains(normalized(word)),
          "sayfa \(index + 1): \(word) bulunamadı — PDFKit metni: \(text)")
      }
    }
  }

  // MARK: - (3) görüntü kimliği kaynak == çıktı

  func testImageIdentityMatchesSource() async throws {
    _ = try qpdf()
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kaynak.pdf")
    Self.makeFixture(to: source)
    let (output, _) = try await runOverlay(source, in: dir)

    let before = try XCTUnwrap(PDFImageIdentity.pageImageHashes(at: source))
    let after = try XCTUnwrap(PDFImageIdentity.pageImageHashes(at: output))
    XCTAssertEqual(before.count, 2)
    XCTAssertTrue(before.allSatisfy { $0.count == 1 }, "sayfa başına tek görüntü bekleniyordu")
    // qpdf kaynağın içeriğini Form XObject'e sarıyor — gezinti formun İÇİNE inmeseydi çıktı
    // tarafı boş liste verirdi ve bu eşitlik düşerdi.
    XCTAssertEqual(before, after)
    XCTAssertEqual(PDFImageIdentity.changedPages(source: before, output: after), [])
    XCTAssertEqual(PDFImageIdentity.changedPages(source: before, output: [after[0], []]), [2])
  }

  // MARK: - (4) piksel farkı ≈ 0

  func testPixelsAreUnchanged() async throws {
    _ = try qpdf()
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kaynak.pdf")
    Self.makeFixture(to: source)
    let (output, _) = try await runOverlay(source, in: dir)

    let sourceDoc = try XCTUnwrap(CGPDFDocument(source as CFURL))
    let outputDoc = try XCTUnwrap(CGPDFDocument(output as CFURL))
    for index in 1...2 {
      let diff = try XCTUnwrap(
        OCRVerification.averagePixelDifference(
          pageA: try XCTUnwrap(sourceDoc.page(at: index)),
          pageB: try XCTUnwrap(outputDoc.page(at: index)), dpi: 72))
      XCTAssertLessThanOrEqual(diff, 0.5 / 255, "sayfa \(index) ortalama fark \(diff)")
    }
  }

  // MARK: - (5) kaynak dokunulmamış

  func testSourceBytesAreUntouched() async throws {
    _ = try qpdf()
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kaynak.pdf")
    Self.makeFixture(to: source)
    let before = try sha256(source)
    _ = try await runOverlay(source, in: dir)
    XCTAssertEqual(try sha256(source), before)
  }

  // MARK: - (6) renderScale

  func testRenderScale() throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kaynak.pdf")
    Self.makeFixture(to: source)
    let doc = try XCTUnwrap(CGPDFDocument(source as CFURL))
    for index in 1...2 {
      let page = try XCTUnwrap(doc.page(at: index))
      XCTAssertEqual(
        OCRTextLayer.nativeImageWidth(of: page), Int(Self.pageSizes[index - 1].width))
      XCTAssertEqual(
        OCRTextLayer.renderScale(for: page, resolution: .native(fallbackDPI: 200)), 1.0,
        accuracy: 0.0001)
      XCTAssertEqual(
        OCRTextLayer.renderScale(for: page, resolution: .dpi(200)), 200 / 72, accuracy: 0.0001)
    }

    // Görüntüsüz sayfa → fallback/72.
    let blank = dir.appendingPathComponent("bos.pdf")
    var box = CGRect(x: 0, y: 0, width: 300, height: 300)
    let consumer = try XCTUnwrap(CGDataConsumer(url: blank as CFURL))
    let ctx = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
    ctx.beginPDFPage(nil)
    ctx.endPDFPage()
    ctx.closePDF()
    let blankPage = try XCTUnwrap(CGPDFDocument(blank as CFURL)?.page(at: 1))
    XCTAssertNil(OCRTextLayer.nativeImageWidth(of: blankPage))
    XCTAssertEqual(
      OCRTextLayer.renderScale(for: blankPage, resolution: .native(fallbackDPI: 200)), 200 / 72,
      accuracy: 0.0001)
    // Seçenek değerinin çözümü: auto/boş → native, sayı → dpi.
    XCTAssertEqual(OCROperation.resolution(from: "auto"), .native(fallbackDPI: 200))
    XCTAssertEqual(OCROperation.resolution(from: nil), .native(fallbackDPI: 200))
    XCTAssertEqual(OCROperation.resolution(from: "300"), .dpi(300))
  }

  // MARK: - (7) kelime hizalaması

  /// Basılı kelimenin dikdörtgeni PDFKit'te o kelimeyi seçmeli — katman kelime kutularıyla
  /// basılı kelimenin üstüne binmiş olmalı (satır kutusu ya da kayık bir yerleşim bunu bozar).
  private func assertAligned(
    output: URL, rects: [[String: CGRect]], file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let doc = try XCTUnwrap(PDFDocument(url: output), file: file, line: line)
    for (index, pageRects) in rects.enumerated() {
      let page = try XCTUnwrap(doc.page(at: index), file: file, line: line)
      for (word, rect) in pageRects {
        let selected = page.selection(for: rect.insetBy(dx: 4, dy: 8))?.string ?? ""
        XCTAssertTrue(
          normalized(selected).contains(normalized(word)),
          "sayfa \(index + 1): \(word) dikdörtgeninde seçilen \"\(selected)\"",
          file: file, line: line)
        // Basılı kelimenin dışında (aynı yükseklikte, sağda boş alan) metin YOK.
        let beside = CGRect(x: rect.maxX + 60, y: rect.minY, width: 200, height: rect.height)
        let stray = page.selection(for: beside)?.string ?? ""
        XCTAssertTrue(
          stray.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          "sayfa \(index + 1): \(word) yanındaki boş alanda metin var: \"\(stray)\"",
          file: file, line: line)
      }
    }
  }

  func testWordBoxesAlignWithPrintedWords() async throws {
    _ = try qpdf()
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kaynak.pdf")
    let rects = Self.makeFixture(to: source)
    let (output, _) = try await runOverlay(source, in: dir)
    try assertAligned(output: output, rects: rects)
  }

  // MARK: - (8) /Rotate 90

  /// ÖLÇÜLDÜ (2026-10-03, qpdf 12.4.1): telafisiz katman döndürülmüş sayfada `0 0.754 -0.754 0
  /// 2709 773.7 cm` ile döndürülüp küçültülüyordu. Katmana kaynakla aynı `/Rotate` verilerek
  /// (`OCRTextLayer.rotationArguments`) net dönüşüm birim matrise iner — bu test o telafiyi
  /// çiviler: telafi kaldırılırsa hizalama iddiası düşer.
  func testRotatedPageKeepsTextAndAlignment() async throws {
    let qpdf = try qpdf()
    let dir = try makeTempDirectory()
    let plain = dir.appendingPathComponent("duz.pdf")
    let rects = Self.makeFixture(to: plain)
    let rotated = dir.appendingPathComponent("doner.pdf")
    let rotateRun = try await ProcessRunner.run(
      qpdf, arguments: [plain.path, "--rotate=+90:1", "--", rotated.path])
    XCTAssertTrue(rotateRun.status == 0 || rotateRun.status == 3, rotateRun.stderr)
    let rotatedDoc = try XCTUnwrap(CGPDFDocument(rotated as CFURL))
    XCTAssertEqual(rotatedDoc.page(at: 1)?.rotationAngle, 90)
    XCTAssertEqual(OCRTextLayer.rotationArguments(for: rotatedDoc), ["--rotate=+90:1"])

    let (output, _) = try await runOverlay(rotated, in: dir)
    let outputDoc = try XCTUnwrap(CGPDFDocument(output as CFURL))
    XCTAssertEqual(outputDoc.page(at: 1)?.rotationAngle, 90, "kaynağın /Rotate'i korunmalı")
    XCTAssertEqual(outputDoc.page(at: 2)?.rotationAngle, 0)
    let text = PDFDocument(url: output)?.page(at: 0)?.string ?? ""
    XCTAssertTrue(
      normalized(text).contains(normalized(Self.script.anchorWord)), "metin yok: \(text)")
    try assertAligned(output: output, rects: rects)
  }

  // MARK: - (9) redraw kipi

  func testRedrawModeStillWorks() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kaynak.pdf")
    Self.makeFixture(to: source)
    let (output, note) = try await runOverlay(
      source, in: dir, extra: [SearchablePDFOperation.modeOptionID: "redraw"])
    XCTAssertFalse(note?.contains("lossless overlay") == true, "redraw kipinde overlay notu")
    let text = PDFDocument(url: output)?.page(at: 0)?.string ?? ""
    XCTAssertTrue(
      normalized(text).contains(normalized(Self.script.anchorWord)), "metin yok: \(text)")

    // Tanınmayan kip sessizce varsayılana düşmez.
    do {
      _ = try await runOverlay(source, in: dir, extra: [SearchablePDFOperation.modeOptionID: "x"])
      XCTFail("tanınmayan kip fırlatmalıydı")
    } catch let error as SearchablePDFError {
      XCTAssertEqual(error, .unknownMode("x"))
    }
  }

  // MARK: - (9b) qpdf yoksa overlay fırlatır, redraw üretir (fail-closed)

  /// SAHA ARIZASI (2026-10-03): paket dışı release ikilisi qpdf'i bulamadı, `overlay` sessizce
  /// `redraw`'a düştü ve 64 sayfalık kitap "✓" ile kayıplı üretildi. Artık overlay FIRLATIR ve
  /// çıktı yazılmaz; kayıplı yol yalnız açıkça seçilince çalışır.
  func testOverlayWithoutQPDFFailsClosedButRedrawStillProduces() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kaynak.pdf")
    Self.makeFixture(to: source)
    let noQPDF = SearchablePDFOperation(locateQPDF: { nil })
    let language = [OCROperation.languageOptionID: Self.script.languageKey]

    do {
      _ = try await noQPDF.run(
        file: PDFFileInfo.inspect(source),
        context: OperationContext(outputDirectory: dir, options: language)) { _ in }
      XCTFail("qpdf yokken overlay fırlatmalıydı")
    } catch let error as SearchablePDFError {
      XCTAssertEqual(error, .qpdfMissing)
    }
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
      .filter { $0 != "kaynak.pdf" }
    XCTAssertEqual(leftovers, [], "fırlatan overlay dosya bıraktı")

    var redrawOptions = language
    redrawOptions[SearchablePDFOperation.modeOptionID] = SearchablePDFOperation.redrawMode
    let outcome = try await noQPDF.run(
      file: PDFFileInfo.inspect(source),
      context: OperationContext(outputDirectory: dir, options: redrawOptions)) { _ in }
    guard case .produced(let urls, _) = outcome, let output = urls.first else {
      return XCTFail("redraw kipi üretmedi: \(outcome)")
    }
    let text = PDFDocument(url: output)?.page(at: 0)?.string ?? ""
    XCTAssertTrue(
      normalized(text).contains(normalized(Self.script.anchorWord)), "metin yok: \(text)")
  }

  // MARK: - (10) JPEG uyarısı hata sayılmıyor

  /// Satırlar gerçek bir kitap sayfasında paketli qpdf'in `--check` çıktısından BİREBİR alındı
  /// (çıkış kodu 3). Yayınevi dosyası repoya giremediği için çıktı metni kullanılıyor.
  func testStructureCheckIgnoresPackagedQPDFJPEGWarning() {
    let realOutput = """
      checking sosyal-s10-12.pdf
      PDF Version: 1.3
      File is not encrypted
      File is not linearized
      WARNING: sosyal-s10-12.pdf (offset 1022): error decoding stream data for object 8 0: \
      Wrong JPEG library version: library is 62, caller expects 80
      WARNING: sosyal-s10-12.pdf (offset 1022): stream will be re-processed without filtering \
      to avoid data loss
      """
    let result = PDFStructureCheck.parse(output: realOutput, status: 3)
    XCTAssertTrue(result.isSound, result.summary)
    XCTAssertEqual(result.errors, [])
    // Süzgeç fazla geniş değil: gerçek bir ERROR yine sayılıyor.
    let broken = PDFStructureCheck.parse(
      output: realOutput + "\nERROR: xref table is damaged", status: 2)
    XCTAssertFalse(broken.isSound)
  }

  // MARK: - (11) katman sayfa sayısı uyuşmazlığı

  func testLayerPageCountMismatchThrows() throws {
    let dir = try makeTempDirectory()
    let stub = dir.appendingPathComponent("katman.pdf")
    var box = CGRect(x: 0, y: 0, width: 100, height: 100)
    let consumer = try XCTUnwrap(CGDataConsumer(url: stub as CFURL))
    let ctx = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
    ctx.beginPDFPage(nil)
    ctx.endPDFPage()
    ctx.closePDF()

    XCTAssertNoThrow(try SearchablePDFOperation.checkLayerPageCount(layer: stub, expected: 1))
    XCTAssertThrowsError(try SearchablePDFOperation.checkLayerPageCount(layer: stub, expected: 2))
    { error in
      XCTAssertEqual(
        error as? SearchablePDFError, .layerPageCount(expected: 2, actual: 1))
    }
  }
}
