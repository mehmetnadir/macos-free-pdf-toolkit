import CoreGraphics
import XCTest

@testable import PDFToolsCore

final class BlankPDFTests: XCTestCase {
  private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdftools-blank-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }

  // MARK: - Sayfa sayısı

  func testCreatesExactPageCount() throws {
    let dir = try makeTempDirectory()
    for count in [1, 10, 250] {
      let url = dir.appendingPathComponent("pages-\(count).pdf")
      try BlankPDF.create(pageCount: count, size: .a4, at: url)
      guard let doc = CGPDFDocument(url as CFURL) else {
        return XCTFail("çıktı açılamadı: \(url.path)")
      }
      XCTAssertEqual(doc.numberOfPages, count)
    }
  }

  // MARK: - Boyutlar

  func testA4MediaBoxIsExact() throws {
    let dir = try makeTempDirectory()
    let url = dir.appendingPathComponent("a4.pdf")
    try BlankPDF.create(pageCount: 1, size: .a4, at: url)
    guard let doc = CGPDFDocument(url as CFURL), let page = doc.page(at: 1) else {
      return XCTFail("çıktı açılamadı")
    }
    let box = page.getBoxRect(.mediaBox)
    XCTAssertEqual(Double(box.width), 595.276, accuracy: 0.01)
    XCTAssertEqual(Double(box.height), 841.890, accuracy: 0.01)
  }

  func testLetterPointValues() {
    XCTAssertEqual(PageSize.letter.width, 612, accuracy: 0.0001)
    XCTAssertEqual(PageSize.letter.height, 792, accuracy: 0.0001)
  }

  func testCustomFromMillimeters() {
    let size = PageSize.custom(widthMM: 210, heightMM: 210)
    // 210mm * 72 / 25.4
    let expected = 210.0 * 72.0 / 25.4
    XCTAssertEqual(size.width, expected, accuracy: 0.0001)
    XCTAssertEqual(size.height, expected, accuracy: 0.0001)
  }

  func testLandscapeSwapsDimensionsAndRenamesSize() {
    let landscape = PageSize.a4.landscape()
    XCTAssertEqual(landscape.width, PageSize.a4.height, accuracy: 0.0001)
    XCTAssertEqual(landscape.height, PageSize.a4.width, accuracy: 0.0001)
    XCTAssertNotEqual(landscape.name, PageSize.a4.name)
    XCTAssertTrue(landscape.name.contains("landscape"))
  }

  func testStandardListStartsWithA4() {
    XCTAssertEqual(PageSize.standard.first, PageSize.a4)
  }

  // MARK: - Geçersiz girdi

  func testInvalidPageCountThrowsAndCreatesNoFile() throws {
    let dir = try makeTempDirectory()
    for invalidCount in [0, -3] {
      let url = dir.appendingPathComponent("invalid-\(invalidCount).pdf")
      XCTAssertThrowsError(try BlankPDF.create(pageCount: invalidCount, size: .a4, at: url)) { error in
        XCTAssertEqual(error as? BlankPDFError, .invalidPageCount)
      }
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: url.path),
        "geçersiz sayfa sayısında dosya OLUŞMAMALI")
    }
  }

  func testInvalidPageSizeThrows() throws {
    let dir = try makeTempDirectory()
    let url = dir.appendingPathComponent("invalid-size.pdf")
    let zeroWidth = PageSize(name: "Bad", width: 0, height: 100)
    XCTAssertThrowsError(try BlankPDF.create(pageCount: 1, size: zeroWidth, at: url)) { error in
      XCTAssertEqual(error as? BlankPDFError, .invalidPageSize)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
  }

  // MARK: - Var olan dosyanın üstüne yazma

  func testDoesNotOverwriteExistingFileByDefault() throws {
    let dir = try makeTempDirectory()
    let url = dir.appendingPathComponent("existing.pdf")
    let marker = Data("not a pdf, just a marker".utf8)
    try marker.write(to: url)

    XCTAssertThrowsError(try BlankPDF.create(pageCount: 3, size: .a4, at: url)) { error in
      XCTAssertEqual(error as? BlankPDFError, .writeFailed)
    }
    // Eski içerik DEĞİŞMEMİŞ olmalı.
    XCTAssertEqual(try Data(contentsOf: url), marker)
  }

  func testOverwriteTrueReplacesExistingFile() throws {
    let dir = try makeTempDirectory()
    let url = dir.appendingPathComponent("existing.pdf")
    try BlankPDF.create(pageCount: 1, size: .a4, at: url)

    try BlankPDF.create(pageCount: 5, size: .a4, at: url, overwrite: true)

    guard let doc = CGPDFDocument(url as CFURL) else {
      return XCTFail("çıktı açılamadı")
    }
    XCTAssertEqual(doc.numberOfPages, 5)
  }

  // MARK: - Doğrulama gerçekten çalışıyor mu

  /// Doğrulama GERÇEKTEN ölçüyor mu? Mutlu yolda yazılan dosya zaten doğru olduğu için
  /// diğer testler doğrulama bloğu silinse bile yeşil kalır — bu yüzden `verify` doğrudan,
  /// KASTEN YANLIŞ beklentiyle çağrılır. Üretim koduna test anahtarı koymaya gerek yok.
  func testVerificationCatchesPageCountMismatch() throws {
    let dir = try makeTempDirectory()
    let url = dir.appendingPathComponent("iki-sayfa.pdf")
    try BlankPDF.create(pageCount: 2, size: .a4, at: url)

    XCTAssertNoThrow(try BlankPDF.verify(url, expectedPages: 2, expectedSize: .a4))
    XCTAssertThrowsError(try BlankPDF.verify(url, expectedPages: 3, expectedSize: .a4)) { error in
      guard case .some(.verificationFailed) = error as? BlankPDFError else {
        return XCTFail("beklenen .verificationFailed, gelen: \(error)")
      }
    }
  }

  /// `create` doğrulamayı GERÇEKTEN çağırıyor mu? Mutlu yolda yazılan dosya doğru olduğu için
  /// bu ancak kasten eksik sayfa yazdırılarak görülebilir. Doğrulama çağrısı silinirse bu test
  /// KIRMIZI olur; ayrıca yarım çıktının bırakılmadığını da çiviler.
  func testCreateActuallyRunsVerification() throws {
    let dir = try makeTempDirectory()
    let url = dir.appendingPathComponent("eksik.pdf")
    XCTAssertThrowsError(
      try BlankPDF.create(pageCount: 3, size: .a4, at: url, pagesToWrite: 2)
    ) { error in
      guard case .some(.verificationFailed) = error as? BlankPDFError else {
        return XCTFail("beklenen .verificationFailed, gelen: \(error)")
      }
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: url.path),
      "doğrulama düşünce yarım çıktı bırakılmamalı")
  }

  /// Sayfa sayısı doğru ama KUTU yanlışsa da yakalanmalı — boyut sessizce kaymasın.
  func testVerificationCatchesWrongPageSize() throws {
    let dir = try makeTempDirectory()
    let url = dir.appendingPathComponent("a4.pdf")
    try BlankPDF.create(pageCount: 1, size: .a4, at: url)
    XCTAssertThrowsError(try BlankPDF.verify(url, expectedPages: 1, expectedSize: .letter))
  }

  func testOutputIsReopenableAfterCreate() throws {
    let dir = try makeTempDirectory()
    let url = dir.appendingPathComponent("reopen.pdf")
    try BlankPDF.create(pageCount: 7, size: .letter, at: url)
    guard let doc = CGPDFDocument(url as CFURL) else {
      return XCTFail("çıktı CGPDFDocument ile açılamadı")
    }
    XCTAssertEqual(doc.numberOfPages, 7)
    XCTAssertFalse(doc.isEncrypted)
  }
}
