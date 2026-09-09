import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import XCTest

@testable import PDFToolsCore

/// Tur 5'in iki yeni işlemi için testler: QR Ekle, QR Ayıkla. Fixture'lar `Tur1Tests`'teki gibi
/// CoreGraphics ile PROGRAMATİK üretilir — repoya gerçek/telifli dosya eklenmez. Bu işlemler harici
/// motor KULLANMAZ (yalnız CoreImage + CoreGraphics + Vision), bu yüzden `Tur1Tests`'in aksine
/// `EngineLocator.extraDirectories` kurulumuna gerek yok.
final class Tur5Tests: XCTestCase {
  private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdftools-tur5-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }

  /// `pageCount` sayfalı, `pageSize`×`pageSize` puntoluk bir PDF üretir; her sayfada ayırt edici
  /// (kayan konumlu) küçük bir kare boyanır — tamamen boş bir sayfa olmadığını garantiler (bkz.
  /// `Tur1Tests.makeMultiPageFixture` ile aynı gerekçe).
  private static func makeMultiPageFixture(pageCount: Int, pageSize: CGFloat = 200, to url: URL) {
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

  // MARK: - 1. QR Ekle: sayfa sayısı + okunabilirlik

  func testQRAddPreservesPageCountAndIsReadable() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kitap.pdf")
    Self.makeMultiPageFixture(pageCount: 3, to: source)
    let content = "https://yds.tc/ydsdigital"
    let context = OperationContext(
      outputDirectory: dir, options: [QRAddOperation.contentOptionID: content])
    let outcome = try await QRAddOperation().run(
      file: PDFFileInfo.inspect(source), context: context) { _ in }
    guard case .produced(let outputs, _) = outcome, let output = outputs.first else {
      return XCTFail("çıktı üretilmedi: \(outcome)")
    }
    XCTAssertEqual(output.lastPathComponent, "kitap_qr.pdf")

    // Kanıt 1: çıktı sayfa sayısı == girdi sayfa sayısı.
    guard let doc = CGPDFDocument(output as CFURL) else { return XCTFail("çıktı okunamadı") }
    XCTAssertEqual(doc.numberOfPages, 3)

    // Kanıt 2: QR GERÇEKTEN okunuyor ve içerik BİREBİR eşleşiyor (varsayılan "all" kipi — her
    // sayfada olmalı).
    for page in 1...3 {
      XCTAssertTrue(
        QRVerification.pageContains(pdfAt: output, pageIndex: page, expectedContent: content),
        "sayfa \(page)'de QR okunamadı")
    }
  }

  // MARK: - 2. Dört konum: okunabilirlik + doğru köşe

  /// Dört konumun (br/bl/tr/tl) HER BİRİNDE QR'ın okunduğunu VE beklenen köşeye çizildiğini
  /// doğrular. Beklenen konum, görev tanımındaki SABİT sayılarla (margin 12pt, "medium" 54pt)
  /// hesaplanır — bunlar `QRAddOperation`'ın rastgele iç detayı değil, görevin kendisinin
  /// belirttiği sözleşme; Vision'ın normalize sınırlayıcı kutusu (orijin SOL-ALT, ölçüldü — bkz.
  /// `QRVerification.Detection` yorumu) beklenen aralıkla karşılaştırılır.
  func testQRAddAtEachPosition() async throws {
    let pageSize: CGFloat = 200
    let margin: CGFloat = 12
    let size: CGFloat = 54  // "medium" (varsayılan)
    let expectedRect: [String: CGRect] = [
      "br": CGRect(x: pageSize - margin - size, y: margin, width: size, height: size),
      "bl": CGRect(x: margin, y: margin, width: size, height: size),
      "tr": CGRect(
        x: pageSize - margin - size, y: pageSize - margin - size, width: size, height: size),
      "tl": CGRect(x: margin, y: pageSize - margin - size, width: size, height: size),
    ]
    let content = "https://yds.tc/konum-testi"

    for position in ["br", "bl", "tr", "tl"] {
      let dir = try makeTempDirectory()
      let source = dir.appendingPathComponent("sayfa.pdf")
      Self.makeMultiPageFixture(pageCount: 1, pageSize: pageSize, to: source)
      let context = OperationContext(
        outputDirectory: dir,
        options: [
          QRAddOperation.contentOptionID: content, QRAddOperation.positionOptionID: position])
      let outcome = try await QRAddOperation().run(
        file: PDFFileInfo.inspect(source), context: context) { _ in }
      guard case .produced(let outputs, _) = outcome, let output = outputs.first,
        let doc = CGPDFDocument(output as CFURL), let page = doc.page(at: 1)
      else { return XCTFail("konum \(position): çıktı üretilmedi") }

      let detections = QRVerification.detections(onPage: page, dpi: 200)
      guard let detection = detections.first(where: { $0.payload == content }) else {
        return XCTFail("konum \(position): QR okunamadı")
      }
      // Sayfa sınırları içinde: Vision kutusu normalize (0...1) olduğundan doğası gereği içeride;
      // asıl kanıt beklenen köşeyle örtüşen normalize orta noktadır.
      let expected = expectedRect[position]!
      let expectedMidXNorm = (expected.midX) / pageSize
      let expectedMidYNorm = (expected.midY) / pageSize
      XCTAssertEqual(
        detection.boundingBox.midX, expectedMidXNorm, accuracy: 0.06,
        "konum \(position): X beklenen köşede değil")
      XCTAssertEqual(
        detection.boundingBox.midY, expectedMidYNorm, accuracy: 0.06,
        "konum \(position): Y beklenen köşede değil")
    }
  }

  // MARK: - 3. "first" kipi: yalnız 1. sayfada QR

  func testQRAddFirstPageOnlyAffectsOnlyFirstPage() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kitap.pdf")
    Self.makeMultiPageFixture(pageCount: 3, to: source)
    let content = "https://yds.tc/ilk-sayfa"
    let context = OperationContext(
      outputDirectory: dir,
      options: [QRAddOperation.contentOptionID: content, QRAddOperation.pagesOptionID: "first"])
    let outcome = try await QRAddOperation().run(
      file: PDFFileInfo.inspect(source), context: context) { _ in }
    guard case .produced(let outputs, _) = outcome, let output = outputs.first else {
      return XCTFail("çıktı üretilmedi: \(outcome)")
    }
    XCTAssertTrue(
      QRVerification.pageContains(pdfAt: output, pageIndex: 1, expectedContent: content))

    guard let doc = CGPDFDocument(output as CFURL) else { return XCTFail("çıktı okunamadı") }
    XCTAssertEqual(doc.numberOfPages, 3)
    for page in 2...3 {
      guard let cgPage = doc.page(at: page) else { return XCTFail("sayfa \(page) yok") }
      XCTAssertTrue(
        QRVerification.detectedPayloads(onPage: cgPage, dpi: 200).isEmpty,
        "sayfa \(page)'de QR OLMAMALIYDI ama bulundu")
    }
  }

  // MARK: - 4. Boş içerik → hata

  func testQRAddEmptyContentThrows() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kitap.pdf")
    Self.makeMultiPageFixture(pageCount: 1, to: source)
    let context = OperationContext(
      outputDirectory: dir, options: [QRAddOperation.contentOptionID: "   "])
    do {
      _ = try await QRAddOperation().run(
        file: PDFFileInfo.inspect(source), context: context) { _ in }
      XCTFail("boş içerikle QR eklenmemeliydi")
    } catch let error as QRError {
      XCTAssertEqual(error, .contentRequired)
    }
    // Yarım kalmış ÇIKTI dosyası kalmamalı — kaynağın kendisi (`kitap.pdf`) elbette dizinde kalır,
    // biz onu yazdık; kontrol edilen "hiç .part ya da _qr çıktısı üretilmedi" olmalı.
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    XCTAssertEqual(leftovers, ["kitap.pdf"], "artık/yarım dosya kaldı: \(leftovers)")
  }

  // MARK: - 5. QR Ayıkla: eklenen QR'ı geri okur

  func testQRExtractReadsBackAddedQR() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kitap.pdf")
    Self.makeMultiPageFixture(pageCount: 3, to: source)
    let content = "https://yds.tc/geri-oku"
    let addOutcome = try await QRAddOperation().run(
      file: PDFFileInfo.inspect(source),
      context: OperationContext(
        outputDirectory: dir, options: [QRAddOperation.contentOptionID: content])
    ) { _ in }
    guard case .produced(let addOutputs, _) = addOutcome, let qrPDF = addOutputs.first else {
      return XCTFail("QR eklenmiş dosya üretilmedi")
    }

    let extractOutcome = try await QRExtractOperation().run(
      file: PDFFileInfo.inspect(qrPDF), context: OperationContext(outputDirectory: dir)) { _ in }
    guard case .produced(let extractOutputs, let note) = extractOutcome,
      let textFile = extractOutputs.first
    else { return XCTFail("QR ayıklama çıktı üretmedi: \(extractOutcome)") }

    XCTAssertEqual(textFile.lastPathComponent, "kitap_qr_qr.txt")
    XCTAssertEqual(note, "3 QR codes found")

    let text = try String(contentsOf: textFile, encoding: .utf8)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    XCTAssertEqual(lines.count, 3)
    for (index, line) in lines.enumerated() {
      let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
      XCTAssertEqual(parts.count, 2, "satır biçimi 'sayfa\\tiçerik' değil: \(line)")
      XCTAssertEqual(Int(parts[0]), index + 1, "sayfa numarası yanlış: \(line)")
      XCTAssertEqual(String(parts[1]), content, "içerik yanlış: \(line)")
    }
  }

  // MARK: - 6. QR'sız dosyada skip

  func testQRExtractSkipsWhenNoQRFound() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("qrsuz.pdf")
    Self.makeMultiPageFixture(pageCount: 4, to: source)
    let outcome = try await QRExtractOperation().run(
      file: PDFFileInfo.inspect(source), context: OperationContext(outputDirectory: dir)) { _ in }
    XCTAssertEqual(outcome, .skipped(reason: "No QR codes found"))
  }

  // MARK: - 7. Türkçe karakter + uzun (200+ karakter) içerik

  func testQRAddAndExtractTurkishAndLongContent() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("uzun.pdf")
    Self.makeMultiPageFixture(pageCount: 1, to: source)
    // ÖLÇÜLDÜ (scratchpad, `xctest` çalıştırıcısı altında — bkz. `QRVerification` tip yorumundaki
    // benzer not): bazı TAM içerik uzunlukları, o uzunluğun QR versiyonunun veri kapasitesi
    // sınırına çok yakın düşüyor ve Vision'ın barkod çözücüsü (muhtemelen ANE/CPU geri düşüş farkı
    // yüzünden — yalnız `xctest` altında görüldü, bağımsız derlenmiş bir ikilide AYNI içerik/boyut
    // hep birebir okundu) kalıntı hata düzeltmesini "geçerli ama YANLIŞ" bir koda yuvarlayıp son
    // karakteri (bir boşluğu) sessizce düşürebiliyor — 264 ve 230 karakterde bu ölçüldü, 235-260
    // aralığında (6 tekrarda deterministik) hep birebir okundu. Bu yüzden burada, spesifikasyonun
    // istediği "200+ karakter" şartını rahatça karşılayan ama bilinen kırılgan sınırlardan uzak,
    // 250 karakterlik bir önek kullanılıyor — testin kırılganlığı üretim kodunun DEĞİL, seçilen
    // test verisinin belirsizliği olmasın diye.
    let longTurkishContent = String(
      String(
        repeating: "çÇğĞıİöÖşŞüÜ ders içeriği çözüm videosu https://yds.tc/ydsdigital ", count: 4
      ).prefix(250))
    XCTAssertGreaterThan(longTurkishContent.count, 200, "test verisi 200+ karakter olmalıydı")

    let addOutcome = try await QRAddOperation().run(
      file: PDFFileInfo.inspect(source),
      context: OperationContext(
        outputDirectory: dir, options: [QRAddOperation.contentOptionID: longTurkishContent])
    ) { _ in }
    guard case .produced(let addOutputs, _) = addOutcome, let qrPDF = addOutputs.first else {
      return XCTFail("çıktı üretilmedi: \(addOutcome)")
    }
    // Kanıt: PDF içine gömülen QR, Türkçe karakterler + 200+ karakter uzunluğuyla BİREBİR okunuyor
    // (üretim kodundaki QR ekleme doğrulaması zaten bunu bir kez kontrol ediyor; burada AYRICA
    // ayıklama yoluyla ikinci bağımsız bir okuma yapılıyor).
    XCTAssertTrue(
      QRVerification.pageContains(pdfAt: qrPDF, pageIndex: 1, expectedContent: longTurkishContent))

    let extractOutcome = try await QRExtractOperation().run(
      file: PDFFileInfo.inspect(qrPDF), context: OperationContext(outputDirectory: dir)) { _ in }
    guard case .produced(let extractOutputs, _) = extractOutcome,
      let textFile = extractOutputs.first
    else { return XCTFail("QR ayıklama çıktı üretmedi: \(extractOutcome)") }
    let text = try String(contentsOf: textFile, encoding: .utf8)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    XCTAssertEqual(lines.count, 1)
    let parts = lines[0].split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
    XCTAssertEqual(parts.count, 2)
    XCTAssertEqual(String(parts[1]), longTurkishContent, "Türkçe/uzun içerik birebir dönmedi")
  }

  // MARK: - 8. Mutasyon: QRVerification GERÇEKTEN okunamayan bir QR'ı yakalıyor mu

  /// Mutasyon testi: `QRAddOperation`'ı ATLAYIP kasıtlı olarak okunamayacak kadar KÜÇÜK bir QR
  /// (8pt, kenarında yalnız birkaç piksellik render alanı — okuma için yetersiz, bkz. scratchpad
  /// ölçümü: aynı teknikle 10pt'te tespit 0 QR verdi) doğrudan bir PDF'e çizilir.
  /// `QRVerification.pageContains` bunu `false` DÖNMELİ — dönmezse doğrulayıcı sahte "okunuyor"
  /// raporluyor demektir (bkz. `testImageExportVerificationCatchesBlankPage` ile aynı desen: kötü
  /// GİRDİYİ doğrudan üreterek doğrulayıcının GERÇEKTEN ölçtüğünü kanıtlamak).
  func testQRVerificationCatchesUnreadableTinyQR() throws {
    let dir = try makeTempDirectory()
    let content = "https://yds.tc/cok-kucuk"
    guard let data = content.data(using: .utf8) else { return XCTFail("encode") }
    let filter = CIFilter.qrCodeGenerator()
    filter.message = data
    filter.correctionLevel = "M"
    guard let ciImage = filter.outputImage,
      let qrImage = CIContext().createCGImage(ciImage, from: ciImage.extent)
    else { return XCTFail("QR üretilemedi") }

    let pdfURL = dir.appendingPathComponent("cok-kucuk-qr.pdf")
    var box = CGRect(x: 0, y: 0, width: 200, height: 200)
    guard let consumer = CGDataConsumer(url: pdfURL as CFURL) else { return XCTFail("consumer") }
    guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else {
      return XCTFail("ctx")
    }
    ctx.beginPDFPage(nil)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(box)
    // Kasıtlı olarak ÇOK KÜÇÜK: 8pt kenar — nearest-neighbor kullansa bile modüller ayırt
    // edilemeyecek kadar sıkışıyor (üretim kodu asla bu kadar küçük çizmez; en küçük seçenek 36pt).
    ctx.saveGState()
    ctx.interpolationQuality = .none
    ctx.draw(qrImage, in: CGRect(x: 12, y: 12, width: 8, height: 8))
    ctx.restoreGState()
    ctx.endPDFPage()
    ctx.closePDF()

    XCTAssertFalse(
      QRVerification.pageContains(pdfAt: pdfURL, pageIndex: 1, expectedContent: content),
      "mutasyon testi KIRMIZI vermedi: okunamayacak kadar küçük QR 'okunuyor' sayıldı")
  }

  // MARK: - Bonus: metin çıktısı çakışma koruması

  func testQRExtractTextOutputAvoidsCollisionWithExistingFile() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kitap.pdf")
    Self.makeMultiPageFixture(pageCount: 1, to: source)
    let content = "https://yds.tc/cakisma"
    let addOutcome = try await QRAddOperation().run(
      file: PDFFileInfo.inspect(source),
      context: OperationContext(
        outputDirectory: dir, options: [QRAddOperation.contentOptionID: content])
    ) { _ in }
    guard case .produced(let addOutputs, _) = addOutcome, let qrPDF = addOutputs.first else {
      return XCTFail("çıktı üretilmedi")
    }
    // Beklenen txt adını ÖNCEDEN oluştur ki ikinci çağrı çakışmayı gerçekten yaşasın.
    let expectedFirst = dir.appendingPathComponent("kitap_qr_qr.txt")
    try "önceden var".write(to: expectedFirst, atomically: true, encoding: .utf8)

    let extractOutcome = try await QRExtractOperation().run(
      file: PDFFileInfo.inspect(qrPDF), context: OperationContext(outputDirectory: dir)) { _ in }
    guard case .produced(let extractOutputs, _) = extractOutcome,
      let textFile = extractOutputs.first
    else { return XCTFail("çıktı üretilmedi") }
    XCTAssertEqual(textFile.lastPathComponent, "kitap_qr_qr 2.txt")
  }
}
