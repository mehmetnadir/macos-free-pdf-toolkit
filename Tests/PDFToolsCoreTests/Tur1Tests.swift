import CoreGraphics
import XCTest

@testable import PDFToolsCore

/// Tur 1'in üç yeni işlemi için testler: Birleştir, Parçala, Görüntüye Aktar. Fixture'lar
/// `TrimTests`'teki gibi CoreGraphics ile PROGRAMATİK üretilir — repoya gerçek/telifli dosya
/// eklenmez.
final class Tur1Tests: XCTestCase {
  // Birleştir/Parçala qpdf'i `EngineLocator.find("qpdf")` ile arar; testler `xctest` çalıştırıcısı
  // altında koştuğu için `Bundle.main` yürütülebiliri vendor/bin'e giden gerçek yoldan FARKLI
  // (bkz. UnlockTests'teki aynı desen) — testler için açıkça vendor/bin'i işaret etmek gerekir.
  static let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  override class func setUp() {
    super.setUp()
    EngineLocator.extraDirectories = [repoRoot.appendingPathComponent("vendor/bin")]
  }

  private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdftools-tur1-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }

  private func fixture(_ name: String) -> URL {
    guard let url = Bundle.module.url(forResource: name, withExtension: "pdf", subdirectory: "Fixtures") else {
      fatalError("fixture yok: \(name)")
    }
    return url
  }

  /// `pageCount` sayfalı bir PDF üretir; her sayfada `markerOffset + sayfaNo`'ya göre KONUMU
  /// KAYAN büyükçe bir kare boyanır. Bu, Birleştir testinde "içerik doğru konuma taşındı" (metin
  /// dahil, çünkü glif de nihayetinde pikseldir) kanıtı için ayırt edici bir imza sağlar —
  /// `markerOffset` farklı dosyalar arasında konumların çakışmamasını garantiler.
  private static func makeMultiPageFixture(pageCount: Int, markerOffset: Int = 0, to url: URL) {
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
      let n = markerOffset + i
      let x = Double((n * 17) % 150)
      context.fill(CGRect(x: x, y: 80, width: 40, height: 40))
      context.endPDFPage()
    }
    context.closePDF()
  }

  // MARK: - 1. Birleştir

  func testMergePreservesPageCountAndOrder() async throws {
    let dir = try makeTempDirectory()
    let fileA = dir.appendingPathComponent("a.pdf")
    let fileB = dir.appendingPathComponent("b.pdf")
    Self.makeMultiPageFixture(pageCount: 2, markerOffset: 0, to: fileA)
    Self.makeMultiPageFixture(pageCount: 3, markerOffset: 100, to: fileB)

    let outcome = try await MergeOperation().runCombined(
      files: [PDFFileInfo.inspect(fileA), PDFFileInfo.inspect(fileB)],
      context: OperationContext(outputDirectory: dir)
    ) { _ in }
    guard case .produced(let outputs, _) = outcome, let output = outputs.first else {
      return XCTFail("çıktı üretilmedi: \(outcome)")
    }
    XCTAssertEqual(outputs.count, 1)
    XCTAssertEqual(output.lastPathComponent, "a_merged.pdf")

    // Kanıt 1: çıktı sayfa sayısı == girdilerin toplamı.
    XCTAssertTrue(MergeVerification.pageCountMatches(output, expected: 5))

    // Kanıt 2: her girdinin sayfası çıktıda DOĞRU KONUMA taşınmış (A: 1-2 → çıktı 1-2,
    // B: 1-3 → çıktı 3-5), piksel düzeyinde (metin dahil, çünkü glif de pikseldir).
    XCTAssertTrue(MergeVerification.pagesMatch(input: fileA, inputPage: 1, output: output, outputPage: 1))
    XCTAssertTrue(MergeVerification.pagesMatch(input: fileA, inputPage: 2, output: output, outputPage: 2))
    XCTAssertTrue(MergeVerification.pagesMatch(input: fileB, inputPage: 1, output: output, outputPage: 3))
    XCTAssertTrue(MergeVerification.pagesMatch(input: fileB, inputPage: 2, output: output, outputPage: 4))
    XCTAssertTrue(MergeVerification.pagesMatch(input: fileB, inputPage: 3, output: output, outputPage: 5))
    // Doğrulayıcının GERÇEKTEN konuma baktığının kanıtı: yanlış eşleşme YANLIŞ dönmeli.
    XCTAssertFalse(
      MergeVerification.pagesMatch(input: fileA, inputPage: 1, output: output, outputPage: 3),
      "doğrulayıcı yanlış konumu 'eşleşti' sayıyor")
  }

  func testMergeRequiresAtLeastTwoFiles() async throws {
    let dir = try makeTempDirectory()
    let file = dir.appendingPathComponent("tek.pdf")
    Self.makeMultiPageFixture(pageCount: 2, to: file)
    let outcome = try await MergeOperation().runCombined(
      files: [PDFFileInfo.inspect(file)], context: OperationContext(outputDirectory: dir)) { _ in }
    XCTAssertEqual(outcome, .skipped(reason: "Needs at least two files to merge"))
  }

  func testMergeFailsOnEncryptedInput() async throws {
    let dir = try makeTempDirectory()
    let context = OperationContext(outputDirectory: dir)
    do {
      _ = try await MergeOperation().runCombined(
        files: [PDFFileInfo.inspect(fixture("plain")), PDFFileInfo.inspect(fixture("user-locked"))],
        context: context
      ) { _ in }
      XCTFail("şifreli dosyayla birleştirme başarılı olmamalıydı")
    } catch let error as OperationError {
      XCTAssertEqual(error, .passwordRequired)
    }
    // Yarım kalmış dosya kalmamalı.
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    XCTAssertTrue(leftovers.isEmpty, "artık dosya kaldı: \(leftovers)")
  }

  // MARK: - 2. Parçala

  func testSplitEachPageSeparatelyIsTheDefault() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kitap.pdf")
    Self.makeMultiPageFixture(pageCount: 5, to: source)
    let info = PDFFileInfo.inspect(source)
    // Seçenek verilmedi — "her sayfa ayrı" varsayılanı devrede olmalı.
    let outcome = try await SplitOperation().run(
      file: info, context: OperationContext(outputDirectory: dir)) { _ in }
    guard case .produced(let outputs, _) = outcome else { return XCTFail("çıktı üretilmedi: \(outcome)") }
    XCTAssertEqual(outputs.count, 5)
    XCTAssertTrue(SplitVerification.verify(outputs, expectedTotal: 5))
    XCTAssertTrue(outputs.allSatisfy { $0.deletingLastPathComponent().lastPathComponent == "kitap_parts" })
  }

  func testSplitIntoFixedSizeChunks() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kitap.pdf")
    Self.makeMultiPageFixture(pageCount: 5, to: source)
    let info = PDFFileInfo.inspect(source)
    let context = OperationContext(
      outputDirectory: dir,
      options: [SplitOperation.modeOptionID: "n", SplitOperation.pageCountOptionID: "2"])
    let outcome = try await SplitOperation().run(file: info, context: context) { _ in }
    guard case .produced(let outputs, _) = outcome else { return XCTFail("çıktı üretilmedi: \(outcome)") }
    // 5 sayfa / 2'lik parçalar → 2 + 2 + 1 = 3 parça.
    XCTAssertEqual(outputs.count, 3)
    XCTAssertTrue(SplitVerification.verify(outputs, expectedTotal: 5))
    XCTAssertTrue(outputs.allSatisfy { url in
      guard let doc = CGPDFDocument(url as CFURL) else { return false }
      return doc.numberOfPages > 0
    })
  }

  func testSplitInHalf() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kitap.pdf")
    Self.makeMultiPageFixture(pageCount: 5, to: source)
    let info = PDFFileInfo.inspect(source)
    let context = OperationContext(outputDirectory: dir, options: [SplitOperation.modeOptionID: "half"])
    let outcome = try await SplitOperation().run(file: info, context: context) { _ in }
    guard case .produced(let outputs, _) = outcome else { return XCTFail("çıktı üretilmedi: \(outcome)") }
    XCTAssertEqual(outputs.count, 2)
    XCTAssertTrue(SplitVerification.verify(outputs, expectedTotal: 5))
    let counts = outputs.compactMap { CGPDFDocument($0 as CFURL)?.numberOfPages }
    XCTAssertEqual(Set(counts), Set([3, 2]), "5 sayfa ikiye bölünce 3+2 olmalı (tek sayı → ilk yarı fazla alır)")
  }

  func testSplitSkipsWhenNotEnoughPages() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("tek-sayfa.pdf")
    Self.makeMultiPageFixture(pageCount: 1, to: source)
    let outcome = try await SplitOperation().run(
      file: PDFFileInfo.inspect(source), context: OperationContext(outputDirectory: dir)) { _ in }
    XCTAssertEqual(outcome, .skipped(reason: "Not enough pages to split"))
  }

  func testUniqueDirectoryAvoidsCollisions() throws {
    let dir = try makeTempDirectory()
    let input = dir.appendingPathComponent("kitap.pdf")
    let first = OutputNaming.uniqueDirectory(for: input, suffix: "_parts")
    XCTAssertEqual(first.lastPathComponent, "kitap_parts")
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    let second = OutputNaming.uniqueDirectory(for: input, suffix: "_parts")
    XCTAssertEqual(second.lastPathComponent, "kitap_parts 2")
  }

  // MARK: - 3. Görüntüye Aktar

  func testImageExportProducesOneImagePerPageWithExpectedSizeAndContent() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("sayfalar.pdf")
    Self.makeMultiPageFixture(pageCount: 3, to: source)
    let info = PDFFileInfo.inspect(source)
    let context = OperationContext(
      outputDirectory: dir,
      options: [ImageExportOperation.formatOptionID: "png", ImageExportOperation.dpiOptionID: "150"])
    let outcome = try await ImageExportOperation().run(file: info, context: context) { _ in }
    guard case .produced(let outputs, _) = outcome else { return XCTFail("çıktı üretilmedi: \(outcome)") }

    // Kanıt 1: dosya sayısı == sayfa sayısı.
    XCTAssertEqual(outputs.count, 3)
    XCTAssertEqual(outputs.map(\.lastPathComponent), ["page-001.png", "page-002.png", "page-003.png"])

    for url in outputs {
      guard let result = ImageExportVerification.inspect(url) else {
        return XCTFail("görüntü okunamadı: \(url.lastPathComponent)")
      }
      // Kanıt 2: piksel boyutu dpi × sayfa punto / 72 ± 2 px.
      XCTAssertTrue(
        ImageExportVerification.matchesExpectedSize(
          result, pagePoints: CGSize(width: 200, height: 200), dpi: 150),
        "\(url.lastPathComponent): \(result.width)×\(result.height), 150 dpi × 200pt bekleniyordu")
      // Kanıt 3: görüntü BOŞ DEĞİL.
      XCTAssertGreaterThan(
        result.nonWhitePercent, ImageExportVerification.minNonWhitePercentForNonEmpty,
        "\(url.lastPathComponent) boş görünüyor (mürekkep %\(result.nonWhitePercent))")
    }
  }

  func testImageExportHEICWhenSupportedOnThisMachine() async throws {
    try XCTSkipUnless(ImageExportOperation.heicWriteSupported, "HEIC yazma bu sistemde desteklenmiyor")
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("tek.pdf")
    Self.makeMultiPageFixture(pageCount: 1, to: source)
    let context = OperationContext(
      outputDirectory: dir, options: [ImageExportOperation.formatOptionID: "heic"])
    let outcome = try await ImageExportOperation().run(
      file: PDFFileInfo.inspect(source), context: context) { _ in }
    guard case .produced(let outputs, _) = outcome, let output = outputs.first else {
      return XCTFail("çıktı üretilmedi: \(outcome)")
    }
    XCTAssertEqual(output.pathExtension, "heic")
    XCTAssertNotNil(ImageExportVerification.inspect(output), "HEIC çıktısı okunamadı")
  }

  /// Mutasyon testi: KASITLI olarak tamamen beyaz (boş) tek sayfalık bir PDF verilir; doğrulayıcı
  /// bu görüntüyü "boş" olarak işaretlemeli. Dönmezse doğrulama sahte "dolu" raporluyor demektir.
  func testImageExportVerificationCatchesBlankPage() async throws {
    let dir = try makeTempDirectory()
    let blank = dir.appendingPathComponent("blank.pdf")
    var box = CGRect(x: 0, y: 0, width: 200, height: 200)
    guard let consumer = CGDataConsumer(url: blank as CFURL) else { fatalError("CGDataConsumer") }
    guard let pdfContext = CGContext(consumer: consumer, mediaBox: &box, nil) else {
      fatalError("CGContext")
    }
    pdfContext.beginPDFPage(nil)
    pdfContext.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    pdfContext.fill(box)
    pdfContext.endPDFPage()
    pdfContext.closePDF()

    let outcome = try await ImageExportOperation().run(
      file: PDFFileInfo.inspect(blank), context: OperationContext(outputDirectory: dir)) { _ in }
    guard case .produced(let outputs, _) = outcome, let output = outputs.first else {
      return XCTFail("çıktı üretilmedi: \(outcome)")
    }
    guard let result = ImageExportVerification.inspect(output) else {
      return XCTFail("görüntü okunamadı")
    }
    XCTAssertLessThan(
      result.nonWhitePercent, ImageExportVerification.minNonWhitePercentForNonEmpty,
      "mutasyon testi KIRMIZI vermedi: boş sayfa 'boş değil' sayıldı (mürekkep %\(result.nonWhitePercent))")
  }

  func testImageExportRequiresPasswordForLockedFile() async throws {
    let dir = try makeTempDirectory()
    do {
      _ = try await ImageExportOperation().run(
        file: PDFFileInfo.inspect(fixture("user-locked")), context: OperationContext(outputDirectory: dir)) { _ in }
      XCTFail("şifreli dosya şifresiz işlenmemeliydi")
    } catch let error as OperationError {
      XCTAssertEqual(error, .passwordRequired)
    }
  }
}
