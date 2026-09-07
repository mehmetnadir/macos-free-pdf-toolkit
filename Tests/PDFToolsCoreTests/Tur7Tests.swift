import CoreGraphics
import PDFKit
import XCTest

@testable import PDFToolsCore

/// Tur 7'nin üç yeni işlemi için testler: Filigran Ekle, Sayfa Numarası Ekle, Yer İmleri (dışa/içe
/// aktar). Fixture'lar `Tur1Tests`/`Tur5Tests`'teki gibi CoreGraphics ile PROGRAMATİK üretilir —
/// repoya gerçek/telifli dosya eklenmez. `BookmarkOperation` pdfcpu alt süreci çalıştırdığından
/// (`Tur6Tests`'teki gibi) `EngineLocator.extraDirectories` `vendor/bin`'e ayarlanır.
final class Tur7Tests: XCTestCase {
  static let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  override class func setUp() {
    super.setUp()
    EngineLocator.extraDirectories = [repoRoot.appendingPathComponent("vendor/bin")]
  }

  private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdftools-tur7-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }

  /// `pageCount` sayfalı, `pageSize`×`pageSize` puntoluk bir PDF üretir; her sayfada ayırt edici
  /// (kayan konumlu) küçük bir kare boyanır — tamamen boş bir sayfa olmadığını garantiler VE
  /// metin katmanı İÇERMEZ (bkz. `Tur5Tests.makeMultiPageFixture` ile aynı gerekçe; metin
  /// katmanı olmaması `PageNumberOperation`'ın "numarasız kalmalı" iddiasını rakam sızıntısından
  /// arındırır).
  private static func makeMultiPageFixture(pageCount: Int, pageSize: CGFloat = 300, to url: URL) {
    try? FileManager.default.removeItem(at: url)
    var box = CGRect(x: 0, y: 0, width: pageSize, height: pageSize)
    guard let consumer = CGDataConsumer(url: url as CFURL) else { fatalError("CGDataConsumer") }
    guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
      fatalError("CGContext(consumer:mediaBox:auxiliaryInfo:)")
    }
    for i in 1...pageCount {
      context.beginPDFPage(nil)
      context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
      context.fill(box)
      context.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.7, alpha: 1))
      let x = Double((i * 23) % Int(pageSize - 40))
      context.fill(CGRect(x: x, y: Double(pageSize) / 2 - 10, width: 30, height: 20))
      context.endPDFPage()
    }
    context.closePDF()
  }

  /// `{"bookmarks": [...]}` şemasında bir JSON dosyası yazar — şema pdfcpu'nun GERÇEK ikilisiyle
  /// deneme yapılarak DOĞRULANDI (bkz. `BookmarkOperation` dosya üstü yorumu): düz bir dizi ya da
  /// başka bir sarmalayıcı `"invalid bookmark JSON"` ile reddediliyor.
  private static func writeBookmarkJSON(entries: [(title: String, page: Int)], to url: URL) throws {
    let items = entries.map { "{\"title\": \"\($0.title)\", \"page\": \($0.page)}" }.joined(
      separator: ",\n    ")
    let json = "{\"bookmarks\": [\n    \(items)\n  ]}"
    try json.write(to: url, atomically: true, encoding: .utf8)
  }

  // MARK: - 1. Filigran: sayfa sayısı korunmuş + bölgede mürekkep artmış (BAĞIMSIZ ölçüm)

  func testWatermarkAddPreservesPageCountAndAddsInkInRegion() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kitap.pdf")
    Self.makeMultiPageFixture(pageCount: 3, to: source)
    let context = OperationContext(
      outputDirectory: dir, options: [WatermarkAddOperation.textOptionID: "GİZLİ TASLAK"])
    let outcome = try await WatermarkAddOperation().run(
      file: PDFFileInfo.inspect(source), context: context) { _ in }
    guard case .produced(let outputs, _) = outcome, let output = outputs.first else {
      return XCTFail("çıktı üretilmedi: \(outcome)")
    }
    XCTAssertEqual(output.lastPathComponent, "kitap_filigranli.pdf")

    // Kanıt 1: sayfa sayısı korunmuş.
    guard let doc = CGPDFDocument(output as CFURL) else { return XCTFail("çıktı okunamadı") }
    XCTAssertEqual(doc.numberOfPages, 3)

    // Kanıt 2 (BAĞIMSIZ — `WatermarkAddOperation.run()`'ın kendi iç kapısına GÜVENMEDEN, testin
    // KENDİSİ kaynak/çıktıyı ayrı ayrı render edip mürekkep farkını ölçer): varsayılan konum
    // "center"'da beklenen bölgede GERÇEKTEN ölçülebilir bir mürekkep artışı var mı.
    guard
      let delta = WatermarkVerification.delta(
        sourceURL: source, outputURL: output, pageIndex: 1, position: "center")
    else {
      return XCTFail("mürekkep ölçülemedi")
    }
    XCTAssertGreaterThanOrEqual(
      delta, WatermarkVerification.minDeltaPercent,
      "filigran bölgesinde beklenen mürekkep artışı ölçülmedi (fark: \(delta)%)")
  }

  // MARK: - 2. Filigran: boş içerik → hata

  func testWatermarkAddEmptyTextThrows() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kitap.pdf")
    Self.makeMultiPageFixture(pageCount: 1, to: source)
    let context = OperationContext(
      outputDirectory: dir, options: [WatermarkAddOperation.textOptionID: "   "])
    do {
      _ = try await WatermarkAddOperation().run(
        file: PDFFileInfo.inspect(source), context: context) { _ in }
      XCTFail("boş metinle filigran eklenmemeliydi")
    } catch let error as WatermarkError {
      XCTAssertEqual(error, .textRequired)
    }
    // Yarım kalmış çıktı olmamalı — dizinde yalnız kaynağın kendisi kalmalı.
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    XCTAssertEqual(leftovers, ["kitap.pdf"], "artık/yarım dosya kaldı: \(leftovers)")
  }

  // MARK: - 3. Sayfa numarası: çıkarılan metinde "3 / 6" geçiyor, doğru sayfada (PDFKit, BAĞIMSIZ)

  func testPageNumberDefaultFormatAppearsOnCorrectPage() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kitap.pdf")
    Self.makeMultiPageFixture(pageCount: 6, to: source)
    let outcome = try await PageNumberOperation().run(
      file: PDFFileInfo.inspect(source), context: OperationContext(outputDirectory: dir)) { _ in }
    guard case .produced(let outputs, _) = outcome, let output = outputs.first else {
      return XCTFail("çıktı üretilmedi: \(outcome)")
    }
    XCTAssertEqual(output.lastPathComponent, "kitap_numarali.pdf")

    // BAĞIMSIZ doğrulama: `PageNumberVerification` KULLANILMADAN, doğrudan PDFKit ile — çizim
    // kodunun ürettiği ile aynı formülü paylaşan bir yardımcıya değil, testin KENDİ literal
    // beklenen dizesine (görev tanımındaki örnekle BİREBİR) bakılıyor.
    guard let doc = PDFDocument(url: output) else { return XCTFail("çıktı PDFKit ile açılamadı") }
    XCTAssertEqual(doc.pageCount, 6)
    let page3Text = doc.page(at: 2)?.string ?? ""
    XCTAssertTrue(
      page3Text.contains("3 / 6"), "3. sayfada '3 / 6' bulunamadı, içerik: \(page3Text)")
    // Karşıt kanıt: 3. sayfa metni başka bir sayfanın numarasını İÇERMEMELİ (yanlış sayfaya
    // çizmenin de bu basit "içerir mi" testini geçmeyeceğinin kanıtı).
    XCTAssertFalse(page3Text.contains("5 / 6"))
  }

  // MARK: - 4. Sayfa numarası: startAt=0 ile ilk sayfada numara YOK, 2. sayfa "1" gösterir

  func testPageNumberStartAtZeroSkipsCoverPage() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kitap.pdf")
    Self.makeMultiPageFixture(pageCount: 4, to: source)
    let context = OperationContext(
      outputDirectory: dir, options: [PageNumberOperation.startAtOptionID: "0"])
    let outcome = try await PageNumberOperation().run(
      file: PDFFileInfo.inspect(source), context: context) { _ in }
    guard case .produced(let outputs, _) = outcome, let output = outputs.first else {
      return XCTFail("çıktı üretilmedi: \(outcome)")
    }
    guard let doc = PDFDocument(url: output) else { return XCTFail("çıktı PDFKit ile açılamadı") }

    // Kanıt 1 (spesifikasyonun ZORUNLU kıldığı): 1. (kapak) sayfada HİÇ rakam yok.
    let coverText = doc.page(at: 0)?.string ?? ""
    XCTAssertFalse(
      coverText.contains(where: \.isNumber), "kapak sayfasında rakam bulundu: \(coverText)")

    // Kanıt 2 (ekstra — "kapak sayılmaz" semantiğinin TAM olarak istenen kaydırmayı yaptığının
    // kanıtı): fiziksel 2. sayfa mantıksal "1 / 4" göstermeli, fiziksel numarasını (2) DEĞİL.
    let page2Text = doc.page(at: 1)?.string ?? ""
    XCTAssertTrue(page2Text.contains("1 / 4"), "2. sayfada '1 / 4' bulunamadı: \(page2Text)")
    XCTAssertFalse(page2Text.contains("2 / 4"))
  }

  // MARK: - 5. Yer imi export: JSON doğru sayıda girdi içeriyor

  func testBookmarkExportProducesJSONWithExpectedCount() async throws {
    let dir = try makeTempDirectory()
    let plain = dir.appendingPathComponent("duz.pdf")
    Self.makeMultiPageFixture(pageCount: 5, to: plain)
    guard let pdfcpu = EngineLocator.find("pdfcpu") else { return XCTFail("pdfcpu bulunamadı") }

    // Fixture: pdfcpu'nun KENDİSİYLE üç (biri iç içe) yer imi eklenmiş bir PDF üretilir —
    // CoreGraphics ile doğrudan anahat (outline) eklemenin bir yolu yok, bu yüzden
    // `RepairOperation`/`Tur6Tests` fixture'larındaki gibi gerçek motor çağrısıyla üretiliyor.
    let bookmarkJSON = dir.appendingPathComponent("giris.json")
    try Self.writeBookmarkJSON(
      entries: [("Bölüm 1", 1), ("Bölüm 2", 3), ("Bölüm 3", 5)], to: bookmarkJSON)
    let bookmarked = dir.appendingPathComponent("yerimli-kaynak.pdf")
    let setupResult = try await ProcessRunner.run(
      pdfcpu,
      arguments: [
        "bookmarks", "import", "--replace", plain.path, bookmarkJSON.path, bookmarked.path,
      ])
    XCTAssertEqual(setupResult.status, 0, "fixture kurulumu başarısız: \(setupResult.stderr)")

    let outcome = try await BookmarkOperation().run(
      file: PDFFileInfo.inspect(bookmarked),
      context: OperationContext(
        outputDirectory: dir, options: [BookmarkOperation.modeOptionID: "export"])
    ) { _ in }
    guard case .produced(let outputs, let note) = outcome, let output = outputs.first else {
      return XCTFail("çıktı üretilmedi: \(outcome)")
    }
    XCTAssertEqual(output.lastPathComponent, "yerimli-kaynak_yerimleri.json")
    XCTAssertEqual(note, "3 yer imi dışa aktarıldı")

    // BAĞIMSIZ kanıt: JSON'u testin KENDİSİ ayrıştırıp sayıyor (üretim kodundaki sayaçla AYNI türü
    // (`BookmarkFile`) kullanır ama üretim kodunun `run()`'ı ÇAĞRILMADAN, doğrudan diskten okunur).
    let data = try Data(contentsOf: output)
    let decoded = try JSONDecoder().decode(BookmarkFile.self, from: data)
    XCTAssertEqual(BookmarkOperation.countEntries(decoded.bookmarks), 3)
    XCTAssertEqual(decoded.bookmarks.map(\.title), ["Bölüm 1", "Bölüm 2", "Bölüm 3"])
  }

  // MARK: - 6. Yer imi import: çıktıda beklenen yer imi sayısı var

  func testBookmarkImportProducesExpectedOutlineCount() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("duz.pdf")
    Self.makeMultiPageFixture(pageCount: 4, to: source)
    let bookmarkJSON = dir.appendingPathComponent("yerimleri.json")
    try Self.writeBookmarkJSON(entries: [("Giriş", 1), ("Sonuç", 4)], to: bookmarkJSON)

    let context = OperationContext(
      outputDirectory: dir,
      options: [
        BookmarkOperation.modeOptionID: "import",
        BookmarkOperation.bookmarkFileOptionID: bookmarkJSON.path,
      ])
    let outcome = try await BookmarkOperation().run(
      file: PDFFileInfo.inspect(source), context: context) { _ in }
    guard case .produced(let outputs, let note) = outcome, let output = outputs.first else {
      return XCTFail("çıktı üretilmedi: \(outcome)")
    }
    XCTAssertEqual(output.lastPathComponent, "duz_yerimli.pdf")
    XCTAssertEqual(note, "2 yer imi uygulandı")

    // BAĞIMSIZ kanıt: sayfa sayısı korunmuş VE PDFKit `outlineRoot` üzerinden GERÇEK anahat sayısı.
    guard let doc = CGPDFDocument(output as CFURL) else { return XCTFail("çıktı okunamadı") }
    XCTAssertEqual(doc.numberOfPages, 4)
    XCTAssertEqual(BookmarkVerification.outlineCount(output), 2)
  }

  // MARK: - 7. Yer imi olmayan dosyada export → skip

  func testBookmarkExportSkipsWhenNoBookmarks() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("duz.pdf")
    Self.makeMultiPageFixture(pageCount: 2, to: source)
    let outcome = try await BookmarkOperation().run(
      file: PDFFileInfo.inspect(source), context: OperationContext(outputDirectory: dir)) { _ in }
    XCTAssertEqual(outcome, .skipped(reason: "Yer imi yok"))
    // Yarım/artık dosya kalmamalı.
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    XCTAssertEqual(leftovers, ["duz.pdf"], "artık dosya kaldı: \(leftovers)")
  }
}
