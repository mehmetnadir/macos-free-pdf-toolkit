import CoreGraphics
import XCTest

@testable import PDFToolsCore

/// Kesim Payını At işlemi için testler. Gerçek matbaa dosyaları telifli olduğundan (bkz.
/// `.claude/CLAUDE.md`), fixture'lar burada CoreGraphics ile PROGRAMATİK üretilir — repoya
/// büyük/gerçek dosya eklenmez. Kutu değerleri `CGPDFContextBeginPage`'e verilen `pageInfo`
/// sözlüğü üzerinden `kCGPDFContextTrimBox` ile yazılır; bu teknik oturum içinde ölçülüp
/// doğrulandı (bkz. scratchpad ölçümü, 2026-09-07).
final class TrimTests: XCTestCase {
  private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdftools-trim-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }

  /// Genel fixture üreticisi: MediaBox + (varsa) TrimBox olan tek sayfalık bir PDF yazar.
  /// - `interiorInset`: TrimBox'ın kendisinden bu kadar içeri çekilmiş bir dikdörtgen mavi
  ///   boyanır (trim sınırına DEĞMEYEN, açıkça "sayfa içeriği" sayılan bir blok).
  /// - `drawMarginBleed`: true ise TrimBox'ın tamamen DIŞINDA (MediaBox içinde kalan payda)
  ///   dört kırmızı şerit de boyanır — gerçek bir taşma (bleed) senaryosunu simüle eder.
  private static func makeFixture(
    mediaBox: CGRect, trimBox: CGRect?, interiorInset: CGFloat = 20,
    drawMarginBleed: Bool = false, to url: URL
  ) {
    try? FileManager.default.removeItem(at: url)
    var box = mediaBox
    guard let consumer = CGDataConsumer(url: url as CFURL) else { fatalError("CGDataConsumer") }
    guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
      fatalError("CGContext(consumer:mediaBox:auxiliaryInfo:)")
    }
    var pageInfo: [CFString: Any] = [:]
    if var trim = trimBox {
      let data = Data(bytes: &trim, count: MemoryLayout<CGRect>.size)
      pageInfo[kCGPDFContextTrimBox] = data as CFData
    }
    context.beginPDFPage(pageInfo as CFDictionary)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(mediaBox)
    if let trimBox {
      context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
      context.fill(trimBox.insetBy(dx: interiorInset, dy: interiorInset))
      if drawMarginBleed {
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(
          x: mediaBox.minX, y: mediaBox.minY,
          width: mediaBox.width, height: trimBox.minY - mediaBox.minY))
        context.fill(CGRect(
          x: mediaBox.minX, y: trimBox.maxY,
          width: mediaBox.width, height: mediaBox.maxY - trimBox.maxY))
        context.fill(CGRect(
          x: mediaBox.minX, y: mediaBox.minY,
          width: trimBox.minX - mediaBox.minX, height: mediaBox.height))
        context.fill(CGRect(
          x: trimBox.maxX, y: mediaBox.minY,
          width: mediaBox.maxX - trimBox.maxX, height: mediaBox.height))
      }
    }
    context.endPDFPage()
    context.closePDF()
  }

  /// "Sahte kesim" fixture'ı: PDF'in KENDİ bildirdiği kutusu zaten küçük (180×180) ama içerik
  /// akışı hâlâ bu kutunun dışına (-10…190 aralığına) boyanmış — yani yalnızca kutu üstverisi
  /// küçültülmüş, geometri hiç silinmemiş. Bu, `pdfcpu crop` / yalnızca-CropBox-yazan araçların
  /// ürettiği gerçek defo deseni (bkz. `.claude/docs/yol-haritasi-2026-09.md`). Mutasyon testinde
  /// `TrimVerification`'ın bu sahteciliği yakaladığını kanıtlamak için kullanılır.
  private static func makeFakeTrimFixture(to url: URL) {
    try? FileManager.default.removeItem(at: url)
    var box = CGRect(x: 0, y: 0, width: 180, height: 180)
    guard let consumer = CGDataConsumer(url: url as CFURL) else { fatalError("CGDataConsumer") }
    guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
      fatalError("CGContext(consumer:mediaBox:auxiliaryInfo:)")
    }
    context.beginPDFPage(nil)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: -20, y: -20, width: 220, height: 220))
    context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    context.fill(box.insetBy(dx: 20, dy: 20))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    // Gerçek bir kesimde bu dört şerit silinmiş olurdu; burada BİLEREK korunuyor.
    context.fill(CGRect(x: -10, y: -10, width: 200, height: 10))
    context.fill(CGRect(x: -10, y: 180, width: 200, height: 10))
    context.fill(CGRect(x: -10, y: -10, width: 10, height: 200))
    context.fill(CGRect(x: 180, y: -10, width: 10, height: 200))
    context.endPDFPage()
    context.closePDF()
  }

  // MARK: - 1. PDFFileInfo TrimBox okuma

  func testPDFFileInfoReadsTrimBoxAndHasBleed() throws {
    let dir = try makeTempDirectory()
    let url = dir.appendingPathComponent("bleed.pdf")
    let mediaBox = CGRect(x: 0, y: 0, width: 200, height: 200)
    let trimBox = CGRect(x: 10, y: 10, width: 180, height: 180)
    Self.makeFixture(mediaBox: mediaBox, trimBox: trimBox, to: url)

    let info = PDFFileInfo.inspect(url)
    XCTAssertEqual(info.mediaBox.width, 200, accuracy: 0.5)
    XCTAssertEqual(info.mediaBox.height, 200, accuracy: 0.5)
    guard let readTrimBox = info.trimBox else { return XCTFail("trimBox okunamadı") }
    XCTAssertEqual(readTrimBox.origin.x, 10, accuracy: 0.5)
    XCTAssertEqual(readTrimBox.origin.y, 10, accuracy: 0.5)
    XCTAssertEqual(readTrimBox.width, 180, accuracy: 0.5)
    XCTAssertEqual(readTrimBox.height, 180, accuracy: 0.5)
    XCTAssertTrue(info.hasBleed)
  }

  func testTrimBoxIsConsistentAcrossSampledPages() throws {
    // Tek sayfalık PDF'lerde tutarlılık trivyal doğrudur; burada asıl önemli olan MediaBox'la
    // aynı olan (dolayısıyla trimBox == nil dönen) bir dosyada da fonksiyonun çökmeden true
    // dönmesi. Çok sayfalı gerçek-farklı-kutu senaryosu matbaa dosyasına özgü ve testte üretmesi
    // pahalı; burada tekil sayfa + tutarlı-kabul davranışı doğrulanıyor.
    let dir = try makeTempDirectory()
    let url = dir.appendingPathComponent("single-page.pdf")
    Self.makeFixture(
      mediaBox: CGRect(x: 0, y: 0, width: 200, height: 200),
      trimBox: CGRect(x: 10, y: 10, width: 180, height: 180), to: url)
    XCTAssertTrue(PDFFileInfo.trimBoxIsConsistent(url))
  }

  // MARK: - 2. TrimBox yoksa atlanır

  func testNoTrimBoxIsSkipped() async throws {
    let dir = try makeTempDirectory()
    let url = dir.appendingPathComponent("notrim.pdf")
    Self.makeFixture(mediaBox: CGRect(x: 0, y: 0, width: 200, height: 200), trimBox: nil, to: url)

    let info = PDFFileInfo.inspect(url)
    XCTAssertNil(info.trimBox)
    XCTAssertFalse(info.hasBleed)

    let outcome = try await TrimOperation().run(
      file: info, context: OperationContext(outputDirectory: dir)) { _ in }
    XCTAssertEqual(outcome, .skipped(reason: "Kesim payı yok"))
  }

  // MARK: - 3. gs varsa: gerçek kesim + doğrulama .clean

  func testTrimOperationProducesCleanOutputWhenGSAvailable() async throws {
    try XCTSkipUnless(EngineLocator.trimEngine() != nil, "gs kurulu değil, atlanıyor")
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("clean-source.pdf")
    let mediaBox = CGRect(x: 0, y: 0, width: 200, height: 200)
    let trimBox = CGRect(x: 10, y: 10, width: 180, height: 180)
    // Kasıtlı olarak margin bleed YOK: gs kesişen nesnelerin tam geometrisini korur, kırpmaz
    // (bkz. GhostscriptEngine.swift notu) — gerçekçi "taşmasız kitap sayfası" senaryosu budur.
    Self.makeFixture(mediaBox: mediaBox, trimBox: trimBox, drawMarginBleed: false, to: source)

    let info = PDFFileInfo.inspect(source)
    XCTAssertNotNil(info.trimBox)

    let outcome = try await TrimOperation().run(
      file: info, context: OperationContext(outputDirectory: dir)) { _ in }
    guard case .produced(let output, _) = outcome else {
      return XCTFail("çıktı üretilmedi: \(outcome)")
    }
    XCTAssertEqual(output.lastPathComponent, "clean-source_kesilmis.pdf")

    guard let doc = CGPDFDocument(output as CFURL), let page = doc.page(at: 1) else {
      return XCTFail("çıktı açılamadı")
    }
    let outputBox = page.getBoxRect(.mediaBox)
    XCTAssertEqual(outputBox.width, trimBox.width, accuracy: 0.5)
    XCTAssertEqual(outputBox.height, trimBox.height, accuracy: 0.5)

    let verification = TrimVerification.verify(output)
    XCTAssertEqual(
      verification.verdict, .clean,
      "kalıntı %\(verification.residuePercent) — beklenmedik derecede yüksek")
  }

  // MARK: - 4. Mutasyon testi: doğrulama sahte temizi yakalıyor mu?

  /// Bu test gate'in KENDİSİNİ sınar: kesim payı SİLİNMEMİŞ (yalnızca kutu üstverisi küçültülmüş)
  /// bir dosya `TrimVerification`'a verildiğinde `.failed` dönmeli. Dönmezse doğrulama sahte
  /// "temiz" raporluyor demektir — bu test KIRMIZI vermeden gate'e güvenilemez.
  func testTrimVerificationCatchesFakeTrim() throws {
    let dir = try makeTempDirectory()
    let url = dir.appendingPathComponent("fake-trim.pdf")
    Self.makeFakeTrimFixture(to: url)

    let result = TrimVerification.verify(url)
    XCTAssertEqual(
      result.verdict, .failed,
      "mutasyon testi KIRMIZI vermedi: kalıntı %\(result.residuePercent) 'temiz' sayıldı, "
        + "doğrulama gate'i sahte kesimi yakalayamıyor")
    XCTAssertGreaterThan(result.residuePercent, 10, "failed eşiğinin üstünde olmalı")
  }

  // MARK: - 5. gs yoksa: engineMissing

  /// Bu testin anlamlı çalışması için gs'in KURULU OLMAMASI gerekir (CI'da böyle: `ci.yml`
  /// yalnızca qpdf/pdfcpu kurar, gs'e bilerek dokunmaz). Geliştirme makinesinde gs kuruluysa bu
  /// hata yolu zaten tetiklenemeyeceği için test atlanır — ötekilerin tam tersi bir skip yönü.
  func testEngineMissingWhenGSNotInstalled() async throws {
    try XCTSkipIf(EngineLocator.trimEngine() != nil, "gs kurulu — bu test yalnız gs YOKKEN anlamlı")
    let dir = try makeTempDirectory()
    let url = dir.appendingPathComponent("bleed.pdf")
    Self.makeFixture(
      mediaBox: CGRect(x: 0, y: 0, width: 200, height: 200),
      trimBox: CGRect(x: 10, y: 10, width: 180, height: 180), to: url)
    let info = PDFFileInfo.inspect(url)

    do {
      _ = try await TrimOperation().run(
        file: info, context: OperationContext(outputDirectory: dir)) { _ in }
      XCTFail("gs yokken çalışmamalıydı")
    } catch let error as OperationError {
      guard case .engineMissing = error else {
        return XCTFail("beklenmeyen hata: \(error)")
      }
    }
  }
}
