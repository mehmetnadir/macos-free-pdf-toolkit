import CoreGraphics
import XCTest

@testable import PDFToolsCore

/// "Sayfa Düzenle" (`PageEditOperation` + `PageEditPlan` + `PageEditVerification`) testleri.
/// Fixture `Tur1Tests`'teki gibi CoreGraphics ile PROGRAMATİK üretilir: 6 sayfalık, her sayfada
/// BÜYÜK ve KONUMU sayfa numarasına göre KAYAN bir kare — sayfalar piksel düzeyinde ayırt edilebilir.
final class PageEditTests: XCTestCase {
  // Birleştir/Parçala testlerindeki AYNI desen: qpdf `EngineLocator.find("qpdf")` ile aranıyor,
  // `xctest` çalıştırıcısı altında `Bundle.main` gerçek vendor/bin yolunu vermiyor.
  static let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  override class func setUp() {
    super.setUp()
    EngineLocator.extraDirectories = [repoRoot.appendingPathComponent("vendor/bin")]
  }

  private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdftools-pageedit-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }

  /// `pageCount` sayfalı, her sayfada `sayfaNo * 17 % 150` konumunda BÜYÜK bir kare içeren bir PDF
  /// üretir — `Tur1Tests.makeMultiPageFixture` ile aynı imza mantığı, sayfaları piksel düzeyinde
  /// ayırt etmek için.
  private static func makeMultiPageFixture(pageCount: Int, to url: URL) {
    try? FileManager.default.removeItem(at: url)
    var box = CGRect(x: 0, y: 0, width: 200, height: 300)
    guard let consumer = CGDataConsumer(url: url as CFURL) else { fatalError("CGDataConsumer") }
    guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
      fatalError("CGContext(consumer:mediaBox:auxiliaryInfo:)")
    }
    for i in 1...pageCount {
      context.beginPDFPage(nil)
      context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
      context.fill(box)
      context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
      let x = Double((i * 17) % 150)
      context.fill(CGRect(x: x, y: 200, width: 40, height: 40))
      context.endPDFPage()
    }
    context.closePDF()
  }

  private func fixture(_ name: String) -> URL {
    guard
      let url = Bundle.module.url(forResource: name, withExtension: "pdf", subdirectory: "Fixtures")
    else { fatalError("fixture yok: \(name)") }
    return url
  }

  private func runPageEdit(
    source: URL, dir: URL, pageOrder: String? = nil, rotations: String? = nil
  ) async throws -> OperationOutcome {
    var options: [String: String] = [:]
    if let pageOrder { options[PageEditOperation.pageOrderOptionID] = pageOrder }
    if let rotations { options[PageEditOperation.rotationsOptionID] = rotations }
    let context = OperationContext(outputDirectory: dir, options: options)
    return try await PageEditOperation().run(file: PDFFileInfo.inspect(source), context: context) {
      _ in
    }
  }

  // MARK: - 1. Yeniden sıralama

  func testReorderPagesInRequestedOrder() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kitap.pdf")
    Self.makeMultiPageFixture(pageCount: 6, to: source)

    let outcome = try await runPageEdit(source: source, dir: dir, pageOrder: "3,1,2")
    guard case .produced(let outputs, _) = outcome, let output = outputs.first else {
      return XCTFail("çıktı üretilmedi: \(outcome)")
    }
    XCTAssertEqual(output.lastPathComponent, "kitap_duzenlenmis.pdf")
    XCTAssertEqual(CGPDFDocument(output as CFURL)?.numberOfPages, 3)

    // Kanıt: çıktının i. sayfası, kaynağın plandaki i. sayfasıyla piksel düzeyinde eşleşiyor.
    XCTAssertTrue(
      MergeVerification.pagesMatch(input: source, inputPage: 3, output: output, outputPage: 1))
    XCTAssertTrue(
      MergeVerification.pagesMatch(input: source, inputPage: 1, output: output, outputPage: 2))
    XCTAssertTrue(
      MergeVerification.pagesMatch(input: source, inputPage: 2, output: output, outputPage: 3))
  }

  // MARK: - 2. Silme

  func testDeletePagesNotInOrder() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kitap.pdf")
    Self.makeMultiPageFixture(pageCount: 6, to: source)

    let outcome = try await runPageEdit(source: source, dir: dir, pageOrder: "1,3,5")
    guard case .produced(let outputs, _) = outcome, let output = outputs.first else {
      return XCTFail("çıktı üretilmedi: \(outcome)")
    }
    XCTAssertEqual(CGPDFDocument(output as CFURL)?.numberOfPages, 3)
    XCTAssertTrue(
      MergeVerification.pagesMatch(input: source, inputPage: 1, output: output, outputPage: 1))
    XCTAssertTrue(
      MergeVerification.pagesMatch(input: source, inputPage: 3, output: output, outputPage: 2))
    XCTAssertTrue(
      MergeVerification.pagesMatch(input: source, inputPage: 5, output: output, outputPage: 3))
  }

  // MARK: - 3. Döndürme

  func testRotateSinglePageSwapsEffectiveDimensions() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kitap.pdf")
    Self.makeMultiPageFixture(pageCount: 6, to: source)
    let originalSize = CGPDFDocument(source as CFURL)!.page(at: 1)!.getBoxRect(.mediaBox).size

    let outcome = try await runPageEdit(source: source, dir: dir, rotations: "1:90")
    guard case .produced(let outputs, _) = outcome, let output = outputs.first else {
      return XCTFail("çıktı üretilmedi: \(outcome)")
    }
    let outDoc = CGPDFDocument(output as CFURL)!
    XCTAssertEqual(outDoc.numberOfPages, 6)
    let rotatedPage = outDoc.page(at: 1)!
    XCTAssertEqual(rotatedPage.rotationAngle, 90)

    // Kanıt: 90°'de GÖRÜNTÜLENEN boyut (genişlik/yükseklik) takas olmuş.
    let effective = PageEditVerification.effectiveSize(of: rotatedPage)
    XCTAssertEqual(effective.width, originalSize.height, accuracy: 0.01)
    XCTAssertEqual(effective.height, originalSize.width, accuracy: 0.01)

    // Döndürülmemiş sayfalar etkilenmemiş.
    XCTAssertEqual(outDoc.page(at: 2)!.rotationAngle, 0)
    // İçerik hâlâ doğru sayfaya ait (rotasyon içerik akışını taşımaz, bkz. PageEditVerification).
    XCTAssertTrue(
      MergeVerification.pagesMatch(input: source, inputPage: 1, output: output, outputPage: 1))
  }

  // MARK: - 4. Sıralama + silme + döndürme birlikte

  func testReorderDeleteAndRotateTogether() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kitap.pdf")
    Self.makeMultiPageFixture(pageCount: 6, to: source)

    // Tut: kaynak 4 (başa), 1, 6 — kaynak 4 90°, kaynak 6 180° döndürülsün.
    let outcome = try await runPageEdit(
      source: source, dir: dir, pageOrder: "4,1,6", rotations: "4:90,6:180")
    guard case .produced(let outputs, _) = outcome, let output = outputs.first else {
      return XCTFail("çıktı üretilmedi: \(outcome)")
    }
    let outDoc = CGPDFDocument(output as CFURL)!
    XCTAssertEqual(outDoc.numberOfPages, 3)

    XCTAssertTrue(
      MergeVerification.pagesMatch(input: source, inputPage: 4, output: output, outputPage: 1))
    XCTAssertTrue(
      MergeVerification.pagesMatch(input: source, inputPage: 1, output: output, outputPage: 2))
    XCTAssertTrue(
      MergeVerification.pagesMatch(input: source, inputPage: 6, output: output, outputPage: 3))

    XCTAssertEqual(outDoc.page(at: 1)!.rotationAngle, 90, "kaynak 4 → çıktı 1, 90° bekleniyordu")
    XCTAssertEqual(outDoc.page(at: 2)!.rotationAngle, 0, "kaynak 1 döndürülmedi")
    XCTAssertEqual(outDoc.page(at: 3)!.rotationAngle, 180, "kaynak 6 → çıktı 3, 180° bekleniyordu")
  }

  // MARK: - 5. Geçersiz plan (4 ayrı assert)

  func testInvalidPlanOutOfRangePageNumberThrows() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kitap.pdf")
    Self.makeMultiPageFixture(pageCount: 6, to: source)
    do {
      _ = try await runPageEdit(source: source, dir: dir, pageOrder: "1,2,99")
      XCTFail("aralık dışı sayfa numarasıyla başarılı olmamalıydı")
    } catch let error as PageEditError {
      XCTAssertEqual(error, .pageOutOfRange(99, 6))
    }
  }

  func testInvalidPlanDuplicatePageNumberThrows() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kitap.pdf")
    Self.makeMultiPageFixture(pageCount: 6, to: source)
    do {
      _ = try await runPageEdit(source: source, dir: dir, pageOrder: "1,1,2")
      XCTFail("tekrar eden sayfa numarasıyla başarılı olmamalıydı")
    } catch let error as PageEditError {
      XCTAssertEqual(error, .duplicatePageNumber(1))
    }
  }

  func testInvalidPlanBadRotationDegreeThrows() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kitap.pdf")
    Self.makeMultiPageFixture(pageCount: 6, to: source)
    do {
      _ = try await runPageEdit(source: source, dir: dir, rotations: "1:45")
      XCTFail("geçersiz derece ile başarılı olmamalıydı")
    } catch let error as PageEditError {
      XCTAssertEqual(error, .invalidRotationDegree(45))
    }
  }

  func testInvalidPlanEmptyResultThrows() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kitap.pdf")
    Self.makeMultiPageFixture(pageCount: 6, to: source)
    // Yalnız ayraçlardan oluşan bir değer: "hiçbir sayfa tutma" isteği, tüm sayfaları silmeye eşdeğer.
    do {
      _ = try await runPageEdit(source: source, dir: dir, pageOrder: ",,,")
      XCTFail("boş sonuçla başarılı olmamalıydı")
    } catch let error as PageEditError {
      XCTAssertEqual(error, .emptyResult)
    }
  }

  // MARK: - 6. Mutasyon kanıtı

  /// Doğrulayıcının GERÇEKTEN sıraya baktığının kanıtı: kasten YANLIŞ sıralı bir çıktı üretip
  /// (plan "2,1,3" der ama çıktı "1,2,3" sırasında qpdf ile üretilir) doğrulayıcıya orijinal planla
  /// birlikte veriyoruz — `.failed` dönmeli.
  func testVerificationCatchesWronglyOrderedOutput() throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kitap.pdf")
    Self.makeMultiPageFixture(pageCount: 6, to: source)

    // Planın DEDİĞİ: 2,1,3. Ama qpdf'e KASTEN kimlik sırasıyla (1,2,3) ürettiriyoruz.
    let wrongOutput = dir.appendingPathComponent("yanlis-sirali.pdf")
    let qpdf = EngineLocator.find("qpdf")!
    let task = Process()
    task.executableURL = qpdf
    task.arguments = ["--empty", "--pages", source.path, "1-3", "--", wrongOutput.path]
    try task.run()
    task.waitUntilExit()
    XCTAssertEqual(task.terminationStatus, 0)

    let plan = PageEditPlan(order: [2, 1, 3], rotations: [:])
    let result = PageEditVerification.verify(input: source, plan: plan, output: wrongOutput)
    XCTAssertEqual(
      result.verdict, .failed, "doğrulayıcı yanlış sırayı 'temiz' sayıyor: \(result.message)")
  }

  func testPageEditRequiresPasswordForLockedFile() async throws {
    let dir = try makeTempDirectory()
    do {
      _ = try await PageEditOperation().run(
        file: PDFFileInfo.inspect(fixture("user-locked")),
        context: OperationContext(outputDirectory: dir)
      ) { _ in }
      XCTFail("şifreli dosya şifresiz işlenmemeliydi")
    } catch let error as OperationError {
      XCTAssertEqual(error, .passwordRequired)
    }
  }
}
