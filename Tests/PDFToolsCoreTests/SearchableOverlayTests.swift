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

  /// Fikstürü yazar; sayfa başına her kelimenin sayfa uzayındaki (orijin SOL-ALT, eksen hizalı)
  /// dikdörtgenini döner. `textAngle` (radyan, saat yönünün tersi) kelimeleri görüntüde yan çizer
  /// (yan taranmış sayfa / yan tablo); `mark` sayfaya siyah bir kare ekler (görüntü baytı farklı
  /// ikiz kaynak için).
  @discardableResult
  static func makeFixture(
    to url: URL, textAngle: CGFloat = 0, mark: Bool = false
  ) -> [[String: CGRect]] {
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
      if mark { bitmap.fill(CGRect(x: width - 160, y: 40, width: 120, height: 120)) }
      var pageRects: [String: CGRect] = [:]
      for (wordIndex, word) in script.pages[pageIndex].enumerated() {
        let attrs = [kCTFontAttributeName: font] as CFDictionary
        guard let string = CFAttributedStringCreate(nil, word as CFString, attrs) else {
          fatalError("metin")
        }
        let line = CTLineCreateWithAttributedString(string)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        // Yatay: alt alta satırlar; yan: yan yana sütunlar (metin aşağıdan yukarı akar).
        let origin =
          textAngle == 0
          ? CGPoint(x: 120, y: size.height - 250 - CGFloat(wordIndex) * 300)
          : CGPoint(x: 300 + CGFloat(wordIndex) * 300, y: 250)
        let transform = CGAffineTransform(rotationAngle: textAngle)
          .concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))
        bitmap.saveGState()
        bitmap.concatenate(transform)
        bitmap.textPosition = .zero
        CTLineDraw(line, bitmap)
        bitmap.restoreGState()
        pageRects[word] = CGRect(
          x: 0, y: -descent, width: lineWidth, height: ascent + descent
        ).applying(transform)
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
    _ source: URL, in dir: URL, extra: [String: String] = [:],
    operation: SearchablePDFOperation = SearchablePDFOperation()
  ) async throws -> (url: URL, note: String?) {
    var options = [OCROperation.languageOptionID: Self.script.languageKey]
    options.merge(extra) { _, new in new }
    let outcome = try await operation.run(
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

    let before = try XCTUnwrap(try PDFImageIdentity.pageImageHashes(at: source))
    let after = try XCTUnwrap(try PDFImageIdentity.pageImageHashes(at: output))
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
        // Basılı kelimenin dışında (okuma yönünde, kelimenin bittiği yerden sonraki boş alan)
        // metin YOK — yatay kelimede sağı, yan (aşağıdan yukarı) kelimede üstü.
        let beside =
          rect.height > rect.width
          ? CGRect(x: rect.minX, y: rect.maxY + 60, width: rect.width, height: 200)
          : CGRect(x: rect.maxX + 60, y: rect.minY, width: 200, height: rect.height)
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
  /// Parametreli: +90, +180, +270 ve sayfa başına karışık (`+90:1 +270:2`).
  func testRotatedPagesKeepTextAndAlignment() async throws {
    let cases: [(args: [String], angles: [Int32])] = [
      (["--rotate=+90:1"], [90, 0]),
      (["--rotate=+180:1"], [180, 0]),
      (["--rotate=+270:1"], [270, 0]),
      (["--rotate=+90:1", "--rotate=+270:2"], [90, 270]),
    ]
    for testCase in cases {
      let dir = try makeTempDirectory()
      let plain = dir.appendingPathComponent("duz.pdf")
      let rects = Self.makeFixture(to: plain)
      let rotated = try await rotate(plain, testCase.args, in: dir)
      let rotatedDoc = try XCTUnwrap(CGPDFDocument(rotated as CFURL))
      XCTAssertEqual(
        try OCRTextLayer.rotationArguments(for: rotatedDoc), testCase.args, "\(testCase.args)")

      let (output, _) = try await runOverlay(rotated, in: dir)
      let outputDoc = try XCTUnwrap(CGPDFDocument(output as CFURL))
      for (index, angle) in testCase.angles.enumerated() {
        XCTAssertEqual(
          outputDoc.page(at: index + 1)?.rotationAngle, angle,
          "\(testCase.args) sayfa \(index + 1): kaynağın /Rotate'i korunmalı")
      }
      let text = PDFDocument(url: output)?.page(at: 0)?.string ?? ""
      XCTAssertTrue(
        normalized(text).contains(normalized(Self.script.anchorWord)),
        "\(testCase.args): metin yok: \(text)")
      try assertAligned(output: output, rects: rects)
    }
  }

  private func rotate(_ source: URL, _ args: [String], in dir: URL) async throws -> URL {
    let rotated = dir.appendingPathComponent("doner.pdf")
    let run = try await ProcessRunner.run(
      try qpdf(), arguments: [source.path] + args + ["--", rotated.path])
    XCTAssertTrue(run.status == 0 || run.status == 3, run.stderr)
    return rotated
  }

  // MARK: - (8b) yan metin (inceleme bulgusu 4)

  /// Gerçek döndürülmüş tarama: içerik görüntüde YAN (90° saat yönünün tersi), `/Rotate 90`
  /// sayfayı dik gösteriyor. Vision yan metni okuyor; katman kelimeyi o açıda çizmezse PDFKit
  /// seçimi basılı kelimeye düşmez.
  func testSidewaysScanWithRotateKeepsTextAndAlignment() async throws {
    let dir = try makeTempDirectory()
    let sideways = dir.appendingPathComponent("yan.pdf")
    let rects = Self.makeFixture(to: sideways, textAngle: .pi / 2)
    let upright = try await rotate(sideways, ["--rotate=+90"], in: dir)
    let (output, _) = try await runOverlay(upright, in: dir)
    try assertTextOnEveryPage(output)
    try assertAligned(output: output, rects: rects)
  }

  /// Kitap içindeki yan tablo: `/Rotate` YOK, metin sayfada yan duruyor.
  func testSidewaysTextWithoutRotateKeepsTextAndAlignment() async throws {
    let dir = try makeTempDirectory()
    let sideways = dir.appendingPathComponent("yan-tablo.pdf")
    let rects = Self.makeFixture(to: sideways, textAngle: .pi / 2)
    let (output, _) = try await runOverlay(sideways, in: dir)
    try assertTextOnEveryPage(output)
    try assertAligned(output: output, rects: rects)
  }

  private func assertTextOnEveryPage(
    _ output: URL, file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let doc = try XCTUnwrap(PDFDocument(url: output), file: file, line: line)
    for (index, words) in Self.script.pages.enumerated() {
      let text = doc.page(at: index)?.string ?? ""
      for word in words {
        XCTAssertTrue(
          normalized(text).contains(normalized(word)),
          "sayfa \(index + 1): \(word) yok — PDFKit metni: \(text)", file: file, line: line)
      }
    }
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

  // MARK: - Kapı RET testleri (inceleme bulgusu 1 ve 7)
  //
  // Bindirilmiş ara çıktı, kapılardan ÖNCE `afterOverlay` kancasıyla bozulur. Her test doğru
  // hatanın fırladığını VE çıktı dizininde kaynaktan başka dosya kalmadığını sınar. Yardımcı
  // dosyalar ayrı bir dizinde üretilir.

  /// `dir` içinde kaynağı üretir, kancalı işlemi koşturur, hatayı döner; dizinde artık dosya
  /// kalmadığını doğrular.
  private func rejection(
    bodyFixture: Bool = false,
    hook: @escaping @Sendable (_ output: URL, _ source: URL) async throws -> Void,
    file: StaticString = #filePath, line: UInt = #line
  ) async throws -> Error? {
    _ = try qpdf()
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kaynak.pdf")
    if bodyFixture { Self.makeBodyFixture(to: source) } else { Self.makeFixture(to: source) }
    var thrown: Error?
    do {
      _ = try await runOverlay(
        source, in: dir, operation: SearchablePDFOperation(afterOverlay: hook))
      XCTFail("bozuk çıktı kapılardan geçti", file: file, line: line)
    } catch {
      thrown = error
    }
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
      .filter { $0 != "kaynak.pdf" }
    XCTAssertEqual(leftovers, [], "reddedilen çıktı dosya bıraktı", file: file, line: line)
    return thrown
  }

  /// `output`u `qpdf <alt> --overlay <üst> -- tmp` sonucuyla değiştirir.
  private static func replaceWithOverlay(
    output: URL, under: URL, over: URL, qpdf: URL
  ) async throws {
    let temporary = output.deletingLastPathComponent().appendingPathComponent("bozuk.pdf")
    let run = try await ProcessRunner.run(
      qpdf, arguments: [under.path, "--overlay", over.path, "--", temporary.path])
    guard run.status == 0 || run.status == 3 else { throw UnexpectedOutcome() }
    try FileManager.default.removeItem(at: output)
    try FileManager.default.moveItem(at: temporary, to: output)
  }

  /// Fikstürle aynı sayfa kutularında vektör PDF; `draw` her sayfaya çizer.
  private static func makeVectorPages(
    to url: URL, sizes: [CGSize] = pageSizes, draw: (CGContext, Int, CGSize) -> Void
  ) {
    var dummy = CGRect(x: 0, y: 0, width: 1, height: 1)
    guard let consumer = CGDataConsumer(url: url as CFURL),
      let pdf = CGContext(consumer: consumer, mediaBox: &dummy, nil)
    else { fatalError("PDF bağlamı") }
    for (index, size) in sizes.enumerated() {
      var box = CGRect(origin: .zero, size: size)
      let info: [CFString: Any] = [
        kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
      ]
      pdf.beginPDFPage(info as CFDictionary)
      draw(pdf, index, size)
      pdf.endPDFPage()
    }
    pdf.closePDF()
  }

  /// Kapı c: görüntü baytı farklı ikiz kaynak, çıktının ALTINA bindirilir → görüntü listesi
  /// değişir.
  func testGateCRejectsChangedImageBytes() async throws {
    let qpdf = try qpdf()
    let aux = try makeTempDirectory()
    let twin = aux.appendingPathComponent("ikiz.pdf")
    Self.makeFixture(to: twin, mark: true)
    let error = try await rejection { output, _ in
      try await Self.replaceWithOverlay(output: output, under: twin, over: output, qpdf: qpdf)
    }
    XCTAssertEqual(error as? SearchablePDFError, .imagesChanged(pages: [1, 2]))
  }

  /// Kapı d: çıktı metinsiz kaynağın kopyasıyla değiştirilir → metin bulunamaz.
  func testGateDRejectsOutputWithoutText() async throws {
    let error = try await rejection { output, source in
      try FileManager.default.removeItem(at: output)
      try FileManager.default.copyItem(at: source, to: output)
    }
    XCTAssertEqual(error as? SearchablePDFError, .textNotFound(page: 1))
  }

  /// Kapı d (konum, bulgu 7): metin sayfada VAR ama 550 pt sağa kaymış → `textMisplaced`.
  /// Konum kontrolü kaldırılırsa bu test kırmızı verir (yalnız "sayfada var mı" geçerdi).
  func testGateDRejectsMisplacedText() async throws {
    let qpdf = try qpdf()
    let aux = try makeTempDirectory()
    let shifted = aux.appendingPathComponent("kayik.pdf")
    // Gövde satırları yarım satır aralığı (200 pt) YUKARI kaymış görünmez katman: metin sayfada
    // var, ama OCR'ın bulduğu kutuda (± 1 satır payıyla) yok.
    let font = CTFontCreateWithName("Helvetica" as CFString, Self.bodyFontSize, nil)
    Self.makeVectorPages(to: shifted, sizes: Self.bodyPageSizes) { ctx, index, _ in
      guard index > 0 else { return }
      for (lineIndex, text) in Self.bodyLines.enumerated() {
        let attrs = [kCTFontAttributeName: font] as CFDictionary
        guard let string = CFAttributedStringCreate(nil, text as CFString, attrs) else { return }
        ctx.setTextDrawingMode(.invisible)
        ctx.textPosition = CGPoint(x: 100, y: Self.bodyBaseline(lineIndex) + 200)
        CTLineDraw(CTLineCreateWithAttributedString(string), ctx)
      }
    }
    let error = try await rejection(bodyFixture: true) { output, source in
      try await Self.replaceWithOverlay(output: output, under: source, over: shifted, qpdf: qpdf)
    }
    guard case .textMisplaced(let page) = error as? SearchablePDFError else {
      return XCTFail("textMisplaced bekleniyordu: \(String(describing: error))")
    }
    XCTAssertTrue([2, 3].contains(page), "örnek sayfa gövde sayfası olmalıydı: \(page)")
  }

  // MARK: - Kapı d örnek seçimi (saha: arka kapak yanlış reddi)

  static let bodyPageSizes = Array(repeating: CGSize(width: 1200, height: 1600), count: 3)
  static let bodyFontSize: CGFloat = 56
  static func bodyBaseline(_ index: Int) -> CGFloat { 1300 - CGFloat(index) * 400 }

  static var bodyLines: [String] {
    turkishSupported
      ? [
        "okul kitabı her gün sınıfta okunur", "öğrenciler derste yeni konular öğrenir",
        "bu sayfa arama testi için yazıldı",
      ]
      : [
        "the school book is read in class", "students learn new topics every day",
        "this page was written for search",
      ]
  }

  /// Harf aralıklı büyük harfli dekoratif satırlar: harfler arası 1, kelimeler arası 3 boşluk
  /// (arka kapak altbilgisi benzetimi).
  static var decorativeLines: [String] {
    let words =
      turkishSupported
      ? [["AKILLI", "TAHTA"], ["UYGULAMA", "KİTABI"]] : [["SMART", "BOARD"], ["BOOK", "APPS"]]
    return words.map { line in
      line.map { $0.map(String.init).joined(separator: " ") }.joined(separator: "   ")
    }
  }

  /// 3 sayfa (1200×1600, 1 pt = 1 px): (1) dekoratif harf aralıklı, (2) ve (3) gövde metni.
  static func makeBodyFixture(to url: URL) {
    var dummy = CGRect(x: 0, y: 0, width: 1, height: 1)
    guard let consumer = CGDataConsumer(url: url as CFURL),
      let pdf = CGContext(consumer: consumer, mediaBox: &dummy, nil)
    else { fatalError("PDF bağlamı") }
    for (pageIndex, size) in bodyPageSizes.enumerated() {
      guard
        let bitmap = CGContext(
          data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      else { fatalError("bitmap") }
      bitmap.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
      bitmap.fill(CGRect(origin: .zero, size: size))
      bitmap.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
      let lines = pageIndex == 0 ? decorativeLines : bodyLines
      let font = CTFontCreateWithName(
        "Helvetica" as CFString, pageIndex == 0 ? 70 : bodyFontSize, nil)
      for (lineIndex, text) in lines.enumerated() {
        let attrs = [kCTFontAttributeName: font] as CFDictionary
        guard let string = CFAttributedStringCreate(nil, text as CFString, attrs) else {
          fatalError("metin")
        }
        bitmap.textPosition = CGPoint(x: 100, y: bodyBaseline(lineIndex))
        CTLineDraw(CTLineCreateWithAttributedString(string), bitmap)
      }
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
  }

  /// Dekoratif sayfa örnek seçilmez, gövde sayfaları seçilir; işlem GEÇER, not konumun
  /// doğrulandığını söyler (ölçülemedi notu YOK).
  func testDecorativePageIsNotSampledAndRunPasses() async throws {
    _ = try qpdf()
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("govde.pdf")
    Self.makeBodyFixture(to: source)
    let document = try XCTUnwrap(CGPDFDocument(source as CFURL))
    let result = try OCRTextLayer.write(
      document: document, to: dir.appendingPathComponent("katman.pdf"),
      languages: OCROperation.recognitionLanguages[Self.script.languageKey] ?? ["en-US"],
      resolution: .native(fallbackDPI: 200), progress: { _ in })
    let sampled = SearchablePDFOperation.textGateSamples(result).map(\.pageIndex)
    XCTAssertEqual(Set(sampled), [2, 3], "örnek sayfalar: \(sampled) — \(result.pages)")

    let (_, note) = try await runOverlay(source, in: dir)
    XCTAssertFalse(
      note?.contains(SearchablePDFOperation.noBodyTextNote) == true, note ?? "-")
  }

  /// Uygun gövde satırı hiç yoksa (her satır tek kelime) işlem fırlatmaz; not konumun
  /// doğrulanamadığını SÖYLER.
  func testNoBodyTextPassesWithExplicitNote() async throws {
    _ = try qpdf()
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kaynak.pdf")
    Self.makeFixture(to: source)
    let (_, note) = try await runOverlay(source, in: dir)
    XCTAssertTrue(
      note?.contains(SearchablePDFOperation.noBodyTextNote) == true, note ?? "-")
  }

  func testBodyLineFilterAndCoverage() {
    XCTAssertTrue(OCRTextLayer.isBodyLine(text: "okul kitabı her gün okunur", confidence: 1))
    XCTAssertFalse(OCRTextLayer.isBodyLine(text: "okul kitabı her gün okunur", confidence: 0.5))
    XCTAssertFalse(OCRTextLayer.isBodyLine(text: "üç kelime var", confidence: 1))
    XCTAssertFalse(OCRTextLayer.isBodyLine(text: "% 1 0 0 A k ıllı T o h ta", confidence: 1))
    XCTAssertGreaterThanOrEqual(
      OCRVerification.coverage(of: "bulunmalıdır.", in: "kitap bulunmalıdır"), 0.8)
    XCTAssertLessThan(
      OCRVerification.coverage(of: "okul kitabı her gün", in: "öğrenciler yeni konular"), 0.8)
  }

  /// Kapı e: metin yerinde, görüntü baytları aynı, ama sayfaya GÖRÜNÜR bir vektör kare çizilmiş.
  func testGateERejectsVisibleDrawing() async throws {
    let qpdf = try qpdf()
    let aux = try makeTempDirectory()
    let box = aux.appendingPathComponent("kare.pdf")
    Self.makeVectorPages(to: box) { ctx, _, size in
      ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
      ctx.fill(CGRect(x: size.width - 450, y: 40, width: 400, height: 400))
    }
    let error = try await rejection { output, _ in
      try await Self.replaceWithOverlay(output: output, under: output, over: box, qpdf: qpdf)
    }
    guard case .visualChange(let page, let diff) = error as? SearchablePDFError else {
      return XCTFail("visualChange bekleniyordu: \(String(describing: error))")
    }
    XCTAssertEqual(page, 1)
    XCTAssertGreaterThan(diff, 0.5 / 255)
  }

  /// Kapı f: kaynağın değişiklik zamanı işlem sırasında oynatılır.
  func testGateFRejectsModifiedSource() async throws {
    let error = try await rejection { _, source in
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: source.path)
    }
    XCTAssertEqual(error as? SearchablePDFError, .sourceModified)
  }

  // MARK: - Mevcut metin katmanı (bulgu 8)

  func testExistingTextLayerIsSkipped() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("metinli.pdf")
    let font = CTFontCreateWithName("Helvetica" as CFString, 40, nil)
    Self.makeVectorPages(to: source) { ctx, _, _ in
      let attrs = [kCTFontAttributeName: font] as CFDictionary
      guard let string = CFAttributedStringCreate(nil, "already text" as CFString, attrs) else {
        return
      }
      ctx.textPosition = CGPoint(x: 100, y: 300)
      CTLineDraw(CTLineCreateWithAttributedString(string), ctx)
    }
    for mode in [SearchablePDFOperation.overlayMode, SearchablePDFOperation.redrawMode] {
      let outcome = try await SearchablePDFOperation().run(
        file: PDFFileInfo.inspect(source),
        context: OperationContext(
          outputDirectory: dir, options: [SearchablePDFOperation.modeOptionID: mode])
      ) { _ in }
      XCTAssertEqual(
        outcome, .skipped(reason: SearchablePDFOperation.existingTextLayerReason), mode)
    }
  }

  // MARK: - Okunamayan görüntü akışı (bulgu 3)

  /// Elle yazılmış PDF: görüntü akışı `/FlateDecode` diyor ama baytlar çöp. İki tarafta da
  /// "okunamadı" görmek eşitlik DEĞİLDİR — kimlik fırlatmalı.
  func testUnreadableImageStreamThrows() throws {
    let dir = try makeTempDirectory()
    let url = dir.appendingPathComponent("bozuk-goruntu.pdf")
    try Self.writeRawPDF(
      to: url,
      objects: [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 /Resources << /XObject << /Im1 5 0 R >> >> >>",
        // Kaynaklar sayfada DEĞİL, Pages düğümünde — kalıtım da (bulgu 10) bu dosyayla sınanır.
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Contents 4 0 R >>",
        "<< /Length 30 >>\nstream\nq 100 0 0 100 0 0 cm /Im1 Do Q\nendstream",
        "<< /Type /XObject /Subtype /Image /Width 10 /Height 10 /ColorSpace /DeviceGray "
          + "/BitsPerComponent 8 /Filter /FlateDecode /Length 16 >>\nstream\n"
          + "THIS IS NOT ZLIB\nendstream",
      ])
    let page = try XCTUnwrap(CGPDFDocument(url as CFURL)?.page(at: 1))
    var seen = 0
    PDFImageIdentity.forEachImageStream(in: page) { _ in seen += 1 }
    XCTAssertEqual(seen, 1, "Pages düğümünden kalıtılan görüntü görülmedi")
    XCTAssertThrowsError(try PDFImageIdentity.pageImageHashes(at: url)) { error in
      XCTAssertEqual(error as? PDFImageIdentity.UnreadableImage, .init(page: 1))
    }
  }

  /// Nesne listesinden (1 tabanlı numaralı) geçerli xref'li bir PDF yazar.
  static func writeRawPDF(to url: URL, objects: [String]) throws {
    var data = Data("%PDF-1.4\n".utf8)
    var offsets: [Int] = []
    for (index, body) in objects.enumerated() {
      offsets.append(data.count)
      data.append(Data("\(index + 1) 0 obj\n\(body)\nendobj\n".utf8))
    }
    let xref = data.count
    var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
    for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
    table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
    data.append(Data(table.utf8))
    try data.write(to: url)
  }

  // MARK: - Render edilemeyen sayfa (bulgu 2) ve dpi kırpma (bulgu 5)

  func testUnrenderablePageThrowsInsteadOfCountingAsBlank() throws {
    let dir = try makeTempDirectory()
    let url = dir.appendingPathComponent("bos-kutu.pdf")
    try Self.writeRawPDF(
      to: url,
      objects: [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 0 0] >>",
      ])
    let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
    let page = try XCTUnwrap(document.page(at: 1))
    XCTAssertThrowsError(
      try OCRVerification.recognizeObservations(
        onPage: page, scale: 1, languages: ["en-US"], level: .fast)
    ) { error in XCTAssertTrue(error is OCRVerification.RenderError, "\(error)") }
    XCTAssertThrowsError(
      try OCRTextLayer.write(
        document: document, to: dir.appendingPathComponent("katman.pdf"),
        languages: ["en-US"], resolution: .native(fallbackDPI: 200), progress: { _ in })
    ) { error in XCTAssertEqual(error as? SearchablePDFError, .pageUnreadable(page: 1)) }
  }

  func testRenderScaleIsClampedForExtremeDPI() throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kaynak.pdf")
    Self.makeFixture(to: source)
    let page = try XCTUnwrap(CGPDFDocument(source as CFURL)?.page(at: 1))
    XCTAssertEqual(OCRTextLayer.renderScale(for: page, resolution: .dpi(.infinity)), 6)
    XCTAssertEqual(OCRTextLayer.renderScale(for: page, resolution: .dpi(100_000)), 6)
    XCTAssertEqual(OCRTextLayer.renderScale(for: page, resolution: .dpi(1)), 0.5)
    XCTAssertEqual(OCRTextLayer.renderScale(for: page, resolution: .dpi(.nan)), 1)
    XCTAssertEqual(OCROperation.resolution(from: "inf"), .dpi(.infinity))
  }

  // MARK: - Sıfır boyutlu kutu çizilmez ve sayılmaz (bulgu 11)

  func testZeroSizeWordIsNotDrawnOrCounted() throws {
    var box = CGRect(x: 0, y: 0, width: 100, height: 100)
    let data = NSMutableData()
    let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
    let ctx = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
    ctx.beginPDFPage(nil)
    let point = CGPoint(x: 0.5, y: 0.5)
    let flat = OCRTextLayer.Word(
      text: "x", bottomLeft: point, bottomRight: point, topLeft: point, confidence: 1,
      endsLine: true)
    XCTAssertNil(OCRTextLayer.drawInvisible(flat, pageBox: box, into: ctx))
    let real = OCRTextLayer.Word(
      text: "x", bottomLeft: point, bottomRight: CGPoint(x: 0.7, y: 0.5),
      topLeft: CGPoint(x: 0.5, y: 0.6), confidence: 1, endsLine: true)
    XCTAssertNotNil(OCRTextLayer.drawInvisible(real, pageBox: box, into: ctx))
    ctx.endPDFPage()
    ctx.closePDF()
  }
}
