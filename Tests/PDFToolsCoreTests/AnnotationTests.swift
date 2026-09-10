import CoreGraphics
import XCTest

@testable import PDFToolsCore

/// Kesme motorunun DOSYAYA GÖRE seçilmesi.
///
/// Arka plan (ölçüldü 2026-09-09): `CoreGraphicsTrimEngine` sayfayı yeniden çizerek kestiği
/// için açıklamaları (bağlantı, form alanı) koruyamıyor — gerçek bir dosyada 24 açıklamanın
/// 24'ü kayboldu, aynı dosya Ghostscript ile kesildiğinde hepsi korundu. Kayıp SESSİZ: dosya
/// açılır, sayfalar yerindedir, yalnız bağlantılar çalışmaz. Bu testler o sessizliği kapatır.
final class AnnotationTests: XCTestCase {
  /// Kesim artık VARSAYILAN olarak paketlenmiş qpdf'i kullanıyor (bkz. `QPDFTrimEngine`), o yüzden
  /// bu sınıfın da motor arama yolunu ayarlaması gerekiyor: `xctest` çalıştırıcısı altında
  /// `Bundle.main` test koşucusudur, `vendor/bin` kendiliğinden bulunmaz (aynı kurulum
  /// Tur1Tests/PageEditTests/UnlockTests içinde de var).
  override func setUp() {
    super.setUp()
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    EngineLocator.extraDirectories = [repoRoot.appendingPathComponent("vendor/bin")]
  }

  private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdftools-annot-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// Kesim paylı, tek sayfalık, İSTENEN SAYIDA bağlantı açıklaması taşıyan PDF üretir.
  private static func makeFixture(annotationCount: Int, to url: URL) {
    let mediaBox = CGRect(x: 0, y: 0, width: 200, height: 200)
    var trimBox = CGRect(x: 20, y: 20, width: 160, height: 160)
    guard let consumer = CGDataConsumer(url: url as CFURL) else { return }
    var box = mediaBox
    guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
    let data = Data(bytes: &trimBox, count: MemoryLayout<CGRect>.size)
    context.beginPDFPage([kCGPDFContextTrimBox: data as CFData] as CFDictionary)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(mediaBox)
    context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    context.fill(trimBox.insetBy(dx: 20, dy: 20))
    for index in 0..<annotationCount {
      let rect = CGRect(x: 40, y: 40 + CGFloat(index) * 20, width: 60, height: 14)
      context.setURL(URL(string: "https://example.com/\(index)")! as CFURL, for: rect)
    }
    context.endPDFPage()
    context.closePDF()
  }

  func testCounterSeesLinkAnnotations() throws {
    let dir = try makeTempDirectory()
    let file = dir.appendingPathComponent("baglantili.pdf")
    Self.makeFixture(annotationCount: 3, to: file)
    XCTAssertEqual(PDFAnnotations.count(in: file), 3)
  }

  func testCounterIsZeroWithoutAnnotations() throws {
    let dir = try makeTempDirectory()
    let file = dir.appendingPathComponent("sade.pdf")
    Self.makeFixture(annotationCount: 0, to: file)
    XCTAssertEqual(PDFAnnotations.count(in: file), 0)
  }

  func testCounterIsZeroForUnreadableFile() {
    XCTAssertEqual(PDFAnnotations.count(in: URL(fileURLWithPath: "/yok/olmayan.pdf")), 0)
  }

  /// ASIL SÖZLEŞME: açıklaması olan bir dosya kesilince açıklamalar HAYATTA KALMALI.
  /// Ghostscript kuruluysa motor ona düşmeli; düşmezse bu test kırmızı olur.
  func testTrimKeepsAnnotationsWhenGhostscriptIsAvailable() async throws {
    try XCTSkipUnless(EngineLocator.ghostscript() != nil, "gs kurulu değil")
    let dir = try makeTempDirectory()
    let file = dir.appendingPathComponent("baglantili.pdf")
    Self.makeFixture(annotationCount: 3, to: file)
    XCTAssertEqual(PDFAnnotations.count(in: file), 3, "fixture hazırlığı")

    let info = PDFFileInfo.inspect(file)
    let outcome = try await TrimOperation().run(
      file: info, context: OperationContext(outputDirectory: dir), progress: { _ in })
    guard case .produced(let urls, _) = outcome, let output = urls.first else {
      return XCTFail("kesme çıktı üretmedi: \(outcome)")
    }
    XCTAssertGreaterThan(
      PDFAnnotations.count(in: output), 0,
      "açıklamalar sessizce silindi — motor seçimi CoreGraphics'e düşmüş olmalı")
  }

  /// Açıklama YOKSA hızlı ve sadık yol (CoreGraphics) kullanılabilir; kesme yine çalışmalı.
  func testTrimStillWorksWithoutAnnotations() async throws {
    let dir = try makeTempDirectory()
    let file = dir.appendingPathComponent("sade.pdf")
    Self.makeFixture(annotationCount: 0, to: file)
    let info = PDFFileInfo.inspect(file)
    let outcome = try await TrimOperation().run(
      file: info, context: OperationContext(outputDirectory: dir), progress: { _ in })
    guard case .produced(let urls, _) = outcome, let output = urls.first else {
      return XCTFail("kesme çıktı üretmedi: \(outcome)")
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
  }
}
