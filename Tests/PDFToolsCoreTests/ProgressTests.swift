import CoreGraphics
import XCTest

@testable import PDFToolsCore

/// `GhostscriptEngine`'in `-q` bayrağı olmadan gs'ten gelen "Page N" satırlarını ayrıştırma
/// mantığı için testler. Saf statik fonksiyonlar (`pageNumber(in:)`, `fraction(page:total:)`)
/// test edilir — alt süreç GEREKMEZ, bu yüzden CI'da gs kurulu olmasa da hepsi koşar.
final class ProgressTests: XCTestCase {
  // MARK: - pageNumber(in:)

  func testPageNumberParsesSimpleLine() {
    XCTAssertEqual(GhostscriptEngine.pageNumber(in: "Page 1"), 1)
  }

  func testPageNumberParsesMultiDigit() {
    XCTAssertEqual(GhostscriptEngine.pageNumber(in: "Page 42"), 42)
  }

  func testPageNumberRejectsBareWord() {
    XCTAssertNil(GhostscriptEngine.pageNumber(in: "Page"))
  }

  func testPageNumberRejectsEmptyLine() {
    XCTAssertNil(GhostscriptEngine.pageNumber(in: ""))
  }

  /// gs'in "Processing pages 1 through 5." BAŞLIK satırı — sayfa bildirimi DEĞİL. Yanlış
  /// eşleşirse ilerleme çubuğu tek bir satırda %20'ye zıplar (5 sayfalık kitapta 1/5).
  func testPageNumberRejectsHeaderLine() {
    XCTAssertNil(GhostscriptEngine.pageNumber(in: "Processing pages 1 through 5."))
  }

  func testPageNumberRejectsNonNumericSuffix() {
    XCTAssertNil(GhostscriptEngine.pageNumber(in: "Page abc"))
  }

  func testPageNumberIgnoresSurroundingWhitespace() {
    XCTAssertEqual(GhostscriptEngine.pageNumber(in: "  Page 7  "), 7)
  }

  // MARK: - fraction(page:total:)

  /// Toplam sayfa sayısını AŞAN bir bildirim (gs'in fazladan satır basması) 1.0'ı geçmemeli.
  func testFractionClampsAboveTotal() {
    XCTAssertEqual(GhostscriptEngine.fraction(page: 5, total: 3), 1.0)
  }

  func testFractionComputesRatio() {
    XCTAssertEqual(GhostscriptEngine.fraction(page: 1, total: 4), 0.25, accuracy: 0.0001)
  }

  func testFractionAtCompletion() {
    XCTAssertEqual(GhostscriptEngine.fraction(page: 4, total: 4), 1.0, accuracy: 0.0001)
  }

  // MARK: - Uçtan uca (gs kurulu ise) — gerçek stdout akışının progress'i tetiklediğini doğrular

  /// `TrimTests`'teki kalıpla aynı: gs kurulu değilse (CI) atlanır, kurulu makinede gerçek
  /// bir alt süreç çalıştırıp ilerleme geri çağrısının en az bir kez 0 ile 1 arasında,
  /// ve son çağrının kesin 1.0 olduğunu doğrular.
  func testTrimReportsIntermediateProgressWhenGSAvailable() async throws {
    try XCTSkipUnless(EngineLocator.trimEngine() != nil, "gs kurulu değil, atlanıyor")
    guard let engine = EngineLocator.trimEngine() else { return }

    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdftools-progress-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

    let input = dir.appendingPathComponent("multipage.pdf")
    Self.makeMultiPageFixture(pageCount: 5, to: input)
    let output = dir.appendingPathComponent("out.pdf")

    let box = ProgressBox()
    try await engine.trim(input: input, output: output) { value in
      box.append(value)
    }

    let values = box.values
    XCTAssertEqual(values.first, 0)
    XCTAssertEqual(values.last, 1)
    // En azından bir ara değer (0 < v < 1) görülmeli — donmuş çubuk yerine gerçek ilerleme.
    XCTAssertTrue(values.contains { $0 > 0 && $0 < 1 }, "ara ilerleme bildirimi yok: \(values)")
    XCTAssertTrue(values.allSatisfy { $0 >= 0 && $0 <= 1 })
  }

  private static func makeMultiPageFixture(pageCount: Int, to url: URL) {
    try? FileManager.default.removeItem(at: url)
    var box = CGRect(x: 0, y: 0, width: 200, height: 200)
    guard let consumer = CGDataConsumer(url: url as CFURL) else { fatalError("CGDataConsumer") }
    guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
      fatalError("CGContext(consumer:mediaBox:auxiliaryInfo:)")
    }
    for _ in 0..<pageCount {
      var pageInfo: [CFString: Any] = [:]
      var trim = CGRect(x: 10, y: 10, width: 180, height: 180)
      let data = Data(bytes: &trim, count: MemoryLayout<CGRect>.size)
      pageInfo[kCGPDFContextTrimBox] = data as CFData
      context.beginPDFPage(pageInfo as CFDictionary)
      context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
      context.fill(box)
      context.endPDFPage()
    }
    context.closePDF()
  }
}

/// `progress` geri çağrısı `@Sendable` olduğundan basit bir sınıf yerine kilitli bir kutu
/// kullanılır — testin kendisi async bağlamda çağrıldığından veri yarışı riski taşımaz ama
/// derleyici yine de Sendable uyumu ister.
private final class ProgressBox: @unchecked Sendable {
  private let lock = NSLock()
  private var _values: [Double] = []

  func append(_ value: Double) {
    lock.lock()
    _values.append(value)
    lock.unlock()
  }

  var values: [Double] {
    lock.lock()
    defer { lock.unlock() }
    return _values
  }
}
