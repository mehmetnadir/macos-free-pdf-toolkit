import CoreGraphics
import CoreText
import XCTest

@testable import PDFToolsCore

/// Tur 4'ün iki yeni işlemi için testler: Sıkıştır (üç kademe) ve Şifrele. Fixture'lar
/// `Tur1Tests`'teki gibi CoreGraphics ile PROGRAMATİK üretilir; burada ayrıca CoreText ile
/// GERÇEK metin çizilir (`Tur1Tests`'in yalnız kare işaretli sayfalarından farklı olarak) —
/// sıkıştırma testlerinde "metin korunumu" ölçülebilsin diye.
final class Tur4Tests: XCTestCase {
  // qpdf/gs testleri `xctest` çalıştırıcısı altında koştuğu için `Bundle.main` yürütülebiliri
  // vendor/bin'e giden gerçek yoldan FARKLI (bkz. Tur1Tests/UnlockTests'teki aynı desen).
  static let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  override class func setUp() {
    super.setUp()
    EngineLocator.extraDirectories = [repoRoot.appendingPathComponent("vendor/bin")]
  }

  private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdftools-tur4-tests-\(UUID().uuidString)", isDirectory: true)
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

  /// `pageCount` sayfalı, her sayfasında CoreText ile çizilmiş GERÇEK metin içeren küçük bir PDF
  /// üretir (200×200 punto, `Tur1Tests`'teki kare-işaretli fixture'la aynı boyut ailesi). Metnin
  /// varlığı `CompressVerification.containsTextOperator` ile ölçülür — bu yüzden gerçek bir metin
  /// gösterme operatörü (`Tj`) üretmesi şart, salt görsel bir şekil YETMEZ.
  private static func makeTextFixture(pageCount: Int, to url: URL) {
    try? FileManager.default.removeItem(at: url)
    var box = CGRect(x: 0, y: 0, width: 200, height: 200)
    guard let consumer = CGDataConsumer(url: url as CFURL) else { fatalError("CGDataConsumer") }
    guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
      fatalError("CGContext(consumer:mediaBox:auxiliaryInfo:)")
    }
    let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
    for i in 1...pageCount {
      context.beginPDFPage(nil)
      context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
      context.fill(box)
      context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
      let attrString = NSAttributedString(
        string: "Sayfa \(i) test metni burada uzunca bir cumle olsun ki icerik olsun",
        attributes: [
          kCTFontAttributeName as NSAttributedString.Key: font,
          kCTForegroundColorAttributeName as NSAttributedString.Key:
            CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ])
      let line = CTLineCreateWithAttributedString(attrString)
      context.textPosition = CGPoint(x: 10, y: 100)
      CTLineDraw(line, context)
      context.endPDFPage()
    }
    context.closePDF()
  }

  // MARK: - 1. Sıkıştır — Hafif (qpdf)

  /// Spec 1: hafif sıkıştırma → çıktı geçerli, sayfa sayısı aynı, metin korunmuş.
  func testLightCompressionPreservesPageCountAndText() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("belge.pdf")
    Self.makeTextFixture(pageCount: 3, to: source)
    let info = PDFFileInfo.inspect(source)

    let outcome = try await CompressOperation().run(
      file: info, context: OperationContext(outputDirectory: dir)) { _ in }
    guard case .produced(let outputs, _) = outcome, let output = outputs.first else {
      return XCTFail("çıktı üretilmedi: \(outcome)")
    }
    XCTAssertEqual(output.lastPathComponent, "belge_compressed.pdf")
    XCTAssertTrue(CompressVerification.pageCountMatches(output, expected: 3))

    guard let doc = CGPDFDocument(output as CFURL), let page = doc.page(at: 1) else {
      return XCTFail("çıktı sayfası açılamadı")
    }
    XCTAssertTrue(CompressVerification.containsTextOperator(page), "metin korunmamış")
  }

  // MARK: - 2. Sıkıştır — Görselleştir (raster)

  /// Spec 2: görselleştirme → sayfa sayısı aynı, sayfa boş değil, note'ta metin kaybı uyarısı VAR.
  func testRasterCompressionProducesNonEmptyPagesWithTextLossWarning() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("raster-kaynagi.pdf")
    Self.makeTextFixture(pageCount: 2, to: source)
    let info = PDFFileInfo.inspect(source)
    let context = OperationContext(
      outputDirectory: dir,
      options: [
        CompressOperation.levelOptionID: "raster",
        CompressOperation.dpiOptionID: "150",
        CompressOperation.qualityOptionID: "0.7",
      ])

    let outcome = try await CompressOperation().run(file: info, context: context) { _ in }
    guard case .produced(let outputs, let note) = outcome, let output = outputs.first else {
      return XCTFail("çıktı üretilmedi: \(outcome)")
    }
    XCTAssertTrue(CompressVerification.pageCountMatches(output, expected: 2))

    guard let percent = CompressVerification.nonWhitePercent(output) else {
      return XCTFail("çıktı render edilemedi")
    }
    XCTAssertGreaterThan(
      percent, CompressVerification.minNonWhitePercentForNonEmpty,
      "çıktı sayfası boş görünüyor (mürekkep %\(percent))")
    XCTAssertTrue(CompressVerification.pageSizeMatches(input: source, output: output))

    // Metin katmanı (Tj operatörü) gerçekten kaybolmuş olmalı — raster kademesinin BEKLENEN yan etkisi.
    guard let outDoc = CGPDFDocument(output as CFURL), let outPage = outDoc.page(at: 1) else {
      return XCTFail("çıktı açılamadı")
    }
    XCTAssertFalse(CompressVerification.containsTextOperator(outPage), "raster çıktısında metin KALMAMALI")

    // `note`'ta uyarı her zaman var (küçük sentetik sayfalarda ayrıca "küçülmedi" notu da eklenebilir
    // — rasterin sabit ek yükü tiny bir vektör kaynağı büyütebilir, bkz. testCompression 3; o yüzden
    // burada eşitlik değil `contains` ile kontrol edilir).
    XCTAssertTrue(
      note?.contains(CompressOperation.rasterTextLossWarning) ?? false,
      "metin kaybı uyarısı yok: \(note ?? "nil")")
  }

  // MARK: - 3. Sıkıştır — boyut büyürse `.notSmaller`

  /// Spec 3: boyut büyürse `.notSmaller` bildirimi geliyor ve çıktı SİLİNMİYOR. Küçük, basit
  /// sentetik bir sayfayı "raster" kademesiyle sıkıştırmak GÜVENİLİR biçimde büyütür (ölçüldü,
  /// 2026-09-08: 11.523 → 40.301 bayt — JPEG + PDF sayfa başlığının sabit ek yükü, tiny bir
  /// vektör kaynağından daha büyük) — bu yüzden bu davranışı gerçek bir motor/kod yolunu bozmadan,
  /// DOĞAL olarak tetikleyen bir girdi seçildi.
  func testCompressionNotSmallerIsReportedAndOutputKept() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kucuk-kaynak.pdf")
    Self.makeTextFixture(pageCount: 1, to: source)
    let info = PDFFileInfo.inspect(source)
    let context = OperationContext(
      outputDirectory: dir, options: [CompressOperation.levelOptionID: "raster"])

    let outcome = try await CompressOperation().run(file: info, context: context) { _ in }
    guard case .produced(let outputs, let note) = outcome, let output = outputs.first else {
      return XCTFail("çıktı üretilmedi: \(outcome)")
    }
    guard let note else { return XCTFail("boyut uyarısı beklenirken note nil geldi") }
    XCTAssertTrue(note.contains("didn't shrink"), "boyut uyarısı yok: \(note)")

    // Çıktı SİLİNMEDİ — kanıtsız "başarısız" davranışı da yok, dosya diskte duruyor.
    XCTAssertTrue(FileManager.default.fileExists(atPath: output.path), "çıktı silinmemeliydi")
    let sizeResult = CompressVerification.compareSize(input: source, output: output)
    XCTAssertEqual(sizeResult.verdict, .notSmaller)
    XCTAssertGreaterThanOrEqual(sizeResult.outputBytes, sizeResult.inputBytes)
  }

  // MARK: - 4. Şifrele — gerçek AES + parola kapısı

  /// Spec 4: çıktı şifreli, doğru parola açıyor, YANLIŞ parola açmıyor.
  func testEncryptionOpensWithCorrectPasswordNotWithWrongPassword() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("gizli.pdf")
    Self.makeTextFixture(pageCount: 2, to: source)
    let info = PDFFileInfo.inspect(source)
    let context = OperationContext(
      outputDirectory: dir,
      options: [
        EncryptOperation.userPasswordOptionID: "dogruParola9",
        EncryptOperation.ownerPasswordOptionID: "sahipParola7",
      ])

    let outcome = try await EncryptOperation().run(file: info, context: context) { _ in }
    guard case .produced(let outputs, let note) = outcome, let output = outputs.first else {
      return XCTFail("çıktı üretilmedi: \(outcome)")
    }
    XCTAssertEqual(output.lastPathComponent, "gizli_encrypted.pdf")
    XCTAssertNil(note, "farklı/güçlü parolalarla uyarı beklenmiyordu: \(note ?? "")")

    guard let probe = CGPDFDocument(output as CFURL) else { return XCTFail("çıktı açılamadı") }
    XCTAssertTrue(probe.isEncrypted, "çıktı şifrelenmemiş görünüyor")

    guard let correctAttempt = CGPDFDocument(output as CFURL) else { return XCTFail("çıktı açılamadı") }
    XCTAssertTrue(correctAttempt.unlockWithPassword("dogruParola9"), "doğru parola açmalıydı")
    XCTAssertEqual(correctAttempt.numberOfPages, 2)

    guard let wrongAttempt = CGPDFDocument(output as CFURL) else { return XCTFail("çıktı açılamadı") }
    XCTAssertFalse(wrongAttempt.unlockWithPassword("yanlisParola"), "YANLIŞ parola açmamalıydı")

    XCTAssertTrue(EncryptVerification.verify(output, userPassword: "dogruParola9"))
    XCTAssertFalse(EncryptVerification.verify(output, userPassword: "yanlisParola"))
  }

  // MARK: - 5. Şifrele — parolasız istek hata verir

  /// Spec 5: parolasız şifreleme isteği hata veriyor.
  func testEncryptionWithoutAnyPasswordFails() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("parolasiz.pdf")
    Self.makeTextFixture(pageCount: 1, to: source)
    let info = PDFFileInfo.inspect(source)

    do {
      _ = try await EncryptOperation().run(
        file: info, context: OperationContext(outputDirectory: dir)) { _ in }
      XCTFail("parolasız şifreleme isteği başarılı olmamalıydı")
    } catch let error as EncryptError {
      XCTAssertEqual(error, .noPasswordProvided)
    }
    // Kaynak dışında (gizli `.part.pdf` gibi) yarım kalmış bir dosya kalmamalı — hata parola
    // kontrolünde, herhangi bir qpdf çağrısından ÖNCE fırlatıldığı için üretilecek bir partial da yok.
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    XCTAssertEqual(leftovers, ["parolasiz.pdf"], "artık dosya kaldı: \(leftovers)")
  }

  // MARK: - 6. Şifrele — zaten şifreli dosya atlanır

  /// Spec 6: zaten şifreli dosya `.skipped`.
  func testEncryptionSkipsAlreadyEncryptedFile() async throws {
    let dir = try makeTempDirectory()
    let context = OperationContext(
      outputDirectory: dir, options: [EncryptOperation.userPasswordOptionID: "yeniParola"])
    let outcome = try await EncryptOperation().run(
      file: PDFFileInfo.inspect(fixture("user-locked")), context: context) { _ in }
    XCTAssertEqual(outcome, .skipped(reason: "Already encrypted"))
  }

  // MARK: - 7. Sıkıştır — Güçlü (Ghostscript)

  /// Spec 7 (var): gs kuruluysa "strong" kademesi çalışır, metin korunur (algısal kayıplı ama
  /// vektör/metin katmanı KALIR — yalnız görüntüler yeniden örneklenir).
  func testStrongCompressionWorksWhenGhostscriptInstalled() async throws {
    try XCTSkipUnless(EngineLocator.ghostscript() != nil, "gs kurulu değil, atlanıyor")
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("guclu.pdf")
    Self.makeTextFixture(pageCount: 2, to: source)
    let info = PDFFileInfo.inspect(source)
    let context = OperationContext(
      outputDirectory: dir, options: [CompressOperation.levelOptionID: "strong"])

    let outcome = try await CompressOperation().run(file: info, context: context) { _ in }
    guard case .produced(let outputs, _) = outcome, let output = outputs.first else {
      return XCTFail("çıktı üretilmedi: \(outcome)")
    }
    XCTAssertTrue(CompressVerification.pageCountMatches(output, expected: 2))
    guard let doc = CGPDFDocument(output as CFURL), let page = doc.page(at: 1) else {
      return XCTFail("çıktı açılamadı")
    }
    XCTAssertTrue(CompressVerification.containsTextOperator(page), "gs sonrası metin kaybolmamalı")
  }

  /// Spec 7 (yok): bu testin anlamlı çalışması için gs'in KURULU OLMAMASI gerekir (CI'da böyle —
  /// `TrimTests`'teki aynı desen, paketleme betiği yalnızca qpdf/pdfcpu kurar, gs'e dokunmaz).
  func testStrongCompressionFailsWithClearErrorWhenGhostscriptMissing() async throws {
    try XCTSkipIf(
      EngineLocator.ghostscript() != nil, "gs kurulu — bu test yalnız gs YOKKEN anlamlı")
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("guclu-yok.pdf")
    Self.makeTextFixture(pageCount: 1, to: source)
    let info = PDFFileInfo.inspect(source)
    let context = OperationContext(
      outputDirectory: dir, options: [CompressOperation.levelOptionID: "strong"])
    do {
      _ = try await CompressOperation().run(file: info, context: context) { _ in }
      XCTFail("gs yokken çalışmamalıydı")
    } catch let error as OperationError {
      guard case .engineMissing = error else {
        return XCTFail("beklenmeyen hata: \(error)")
      }
    }
  }

  // MARK: - 8. Mutasyon kanıtı — EncryptVerification gerçekten kontrol ediyor mu?

  /// Mutasyon testi: `EncryptVerification.verify`, ŞİFRELENMEMİŞ (plain) bir dosya için `false`
  /// DÖNMELİ — `probe.isEncrypted` hiç kontrol edilmeden "her zaman true" şeklinde bozulmuş bir
  /// uygulama bu testi KIRMIZI verdirir. Geliştirme sırasında bu fonksiyon kasten
  /// `return true` olacak biçimde bozulup bu testin KIRMIZI verdiği, sonra geri alınıp YEŞİLE
  /// döndüğü doğrulandı (bkz. Tur 4 raporu — "Mutasyon kanıtı" bölümü).
  func testEncryptVerificationCatchesUnencryptedOutput() throws {
    let dir = try makeTempDirectory()
    let plainFile = dir.appendingPathComponent("plain-check.pdf")
    Self.makeTextFixture(pageCount: 1, to: plainFile)
    XCTAssertFalse(
      EncryptVerification.verify(plainFile, userPassword: "herhangi-bir-parola"),
      "doğrulayıcı ŞİFRELENMEMİŞ bir dosyayı 'şifreli' sayıyor")
  }

  // MARK: - Ek: izin seçenekleri qpdf sözdizimini bozmuyor

  /// `permissions = "readonly"` (yazdırma + kopyalama kapalı) → `--print=none --extract=n` ikisi
  /// birlikte qpdf'e geçildiğinde hâlâ geçerli bir şifreli çıktı üretiyor (sözdizimi regresyonuna
  /// karşı ucuz bir bekçi; asıl bayrak doğrulaması `qpdf --show-encryption` ile elle yapıldı,
  /// bkz. Tur 4 raporu).
  func testEncryptionWithReadonlyPermissionsStillProducesValidEncryptedOutput() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("readonly-kaynak.pdf")
    Self.makeTextFixture(pageCount: 1, to: source)
    let info = PDFFileInfo.inspect(source)
    let context = OperationContext(
      outputDirectory: dir,
      options: [
        EncryptOperation.userPasswordOptionID: "okuyucuParola",
        EncryptOperation.ownerPasswordOptionID: "sahipFarkli",
        EncryptOperation.permissionsOptionID: "readonly",
      ])
    let outcome = try await EncryptOperation().run(file: info, context: context) { _ in }
    guard case .produced(let outputs, _) = outcome, let output = outputs.first else {
      return XCTFail("çıktı üretilmedi: \(outcome)")
    }
    XCTAssertTrue(EncryptVerification.verify(output, userPassword: "okuyucuParola"))
  }
}
