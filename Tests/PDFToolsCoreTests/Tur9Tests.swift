import CoreGraphics
import CoreText
import PDFKit
import Vision
import XCTest

@testable import PDFToolsCore

/// Tur 9'un iki yeni işlemi için testler: OCR ile Metin Çıkar, Aranabilir PDF Yap. Fixture'lar
/// `Tur6Tests`'teki gibi CoreGraphics/CoreText ile PROGRAMATİK üretilir — repoya gerçek/telifli
/// dosya eklenmez. "Taranmış" (scanned) benzetimi: metin önce CoreText ile bir BİTMAP'e çizilir,
/// sonra o bitmap TEK görüntü olarak yeni bir PDF sayfasına gömülür — sayfada hiçbir vektör metin
/// operatörü YOKTUR (`page.string` bu sayfalarda hep boş döner, test 4'te doğrudan kontrol edilir),
/// bu yüzden OCR'ın gerçekten görüntüden okuduğu kanıtlanmış olur.
final class Tur9Tests: XCTestCase {
  private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdftools-tur9-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }

  // MARK: - Fixture üreticileri

  /// Bilinen Türkçe karakterler (İ, ş, ğ, ü, ö, ç, ı) içeren üç satırı CoreText ile bir bitmap'e
  /// çizer, sonra o bitmap'i TEK sayfalık bir PDF'e görüntü olarak gömer — vektör metin YOK,
  /// gerçek bir "taranmış sayfa" benzetimi (bkz. `.claude/docs/yol-haritasi-2026-09.md`'deki ölçüm
  /// yöntemiyle AYNI fikir: "önce görselleştirilerek metin katmanı yok edildi").
  @discardableResult
  private static func makeScannedTurkishFixture(pageSize: CGFloat = 450, to url: URL) -> [String] {
    let lines = [
      "İSTİKLAL MARŞI ÖRNEK ŞİİR", "öğüt ve düşünce üzerine", "çiçek ığdır güç bulur",
    ]
    let scale: CGFloat = 3
    let width = Int(pageSize * scale)
    let height = Int(pageSize * scale)
    guard
      let bitmapCtx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { fatalError("CGContext (bitmap)") }
    bitmapCtx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    bitmapCtx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    bitmapCtx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    let font =
      CTFontCreateUIFontForLanguage(.system, 24 * scale, nil)
      ?? CTFontCreateWithName("Helvetica" as CFString, 24 * scale, nil)
    var y = CGFloat(height) - 70 * scale
    for text in lines {
      let attrs = [kCTFontAttributeName: font] as CFDictionary
      guard let attrString = CFAttributedStringCreate(nil, text as CFString, attrs) else {
        fatalError("CFAttributedStringCreate")
      }
      let ctLine = CTLineCreateWithAttributedString(attrString)
      bitmapCtx.textPosition = CGPoint(x: 20 * scale, y: y)
      CTLineDraw(ctLine, bitmapCtx)
      y -= 55 * scale
    }
    guard let image = bitmapCtx.makeImage() else { fatalError("makeImage") }

    try? FileManager.default.removeItem(at: url)
    var box = CGRect(x: 0, y: 0, width: pageSize, height: pageSize)
    guard let consumer = CGDataConsumer(url: url as CFURL) else { fatalError("CGDataConsumer") }
    guard let pdfCtx = CGContext(consumer: consumer, mediaBox: &box, nil) else {
      fatalError("CGContext (pdf)")
    }
    pdfCtx.beginPDFPage(nil)
    pdfCtx.draw(image, in: box)
    pdfCtx.endPDFPage()
    pdfCtx.closePDF()
    return lines
  }

  /// Gerçek glif (`page.string`'in çözebileceği bir metin katmanı) ile TEK sayfalık bir PDF üretir
  /// — `Tur6Tests.makeTextFixture` ile AYNI teknik.
  private static func makeVectorTextFixture(text: String, to url: URL) {
    try? FileManager.default.removeItem(at: url)
    var box = CGRect(x: 0, y: 0, width: 320, height: 150)
    guard let consumer = CGDataConsumer(url: url as CFURL) else { fatalError("CGDataConsumer") }
    guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
      fatalError("CGContext")
    }
    let font = CTFontCreateWithName("Helvetica" as CFString, 22, nil)
    context.beginPDFPage(nil)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(box)
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    let attrs = [kCTFontAttributeName: font] as CFDictionary
    guard let attrString = CFAttributedStringCreate(nil, text as CFString, attrs) else {
      fatalError("CFAttributedStringCreate")
    }
    let line = CTLineCreateWithAttributedString(attrString)
    context.textPosition = CGPoint(x: 10, y: 70)
    CTLineDraw(line, context)
    context.endPDFPage()
    context.closePDF()
  }

  /// Yalnızca beyaz (tamamen boş) `pageCount` sayfalı bir PDF — OCR'ın "hiçbir şey tanınamadı"
  /// yolunu test etmek için.
  private static func makeBlankFixture(pageCount: Int, to url: URL) {
    try? FileManager.default.removeItem(at: url)
    var box = CGRect(x: 0, y: 0, width: 200, height: 200)
    guard let consumer = CGDataConsumer(url: url as CFURL) else { fatalError("CGDataConsumer") }
    guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
      fatalError("CGContext")
    }
    for _ in 0..<pageCount {
      context.beginPDFPage(nil)
      context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
      context.fill(box)
      context.endPDFPage()
    }
    context.closePDF()
  }

  /// Ölçülen İ/I hatasına karşı dayanıklı karşılaştırma: her iki tarafta da noktalı büyük İ'yi
  /// noktasız I'ya çevirip karşılaştırır (bkz. `OCRVerification` dosya üstü yorumu — bu bilinen
  /// hata rastgele/kelimeye bağlı değil, ölçülmüş bir Vision davranışı; test verisini KIRILGAN
  /// yapmasın diye normalize ediliyor).
  ///
  /// CI ÖLÇÜMÜ (GitHub `macos-15` runner, 2026-09-08): bu testin İLK sürümü CI'da KIRMIZI verdi —
  /// o runner'da Vision'ın `tr-TR` dil varlıkları kurulu değilmiş ve tanıma SESSİZCE aksansız/
  /// İngilizce benzeri bir modele düşmüş (`İSTİKLAL MARŞI ÖRNEK ŞİİR` → `iSTiKLAL MARSI ÖRNEK
  /// SiiR` — Ş/İ/ş/ğ kayboldu, kelimelerin kendisi DOĞRU okundu). Bu yüzden "OCR kelimeleri okudu
  /// mu" sorusu artık TÜM Türkçe aksanları ASCII karşılığına indirgeyerek (`normalizedTurkishContains`)
  /// sınanıyor — ortamdan BAĞIMSIZ ama sinyal kaybetmeden. Aksanların BİREBİR doğru okunduğu ayrı
  /// bir testte (`testOCRTurkishDiacriticsAreCorrectWhenLanguageSupported`), yalnız `tr-TR`
  /// GERÇEKTEN desteklendiğinde, sınanıyor.
  private func normalizedTurkishContains(_ haystack: String, _ needle: String) -> Bool {
    func normalize(_ s: String) -> String {
      var result = s
      let pairs: [(String, String)] = [
        ("İ", "i"), ("I", "i"), ("ı", "i"), ("Ş", "s"), ("ş", "s"), ("Ğ", "g"), ("ğ", "g"),
        ("Ü", "u"), ("ü", "u"), ("Ö", "o"), ("ö", "o"), ("Ç", "c"), ("ç", "c"),
      ]
      for (from, to) in pairs { result = result.replacingOccurrences(of: from, with: to) }
      return result.lowercased()
    }
    return normalize(haystack).contains(normalize(needle))
  }

  // MARK: - 1. OCR: taranmış fixture'dan beklenen kelimeler (Türkçe karakterler dahil)

  func testOCRRecognizesTurkishTextFromScannedFixture() async throws {
    // CI teşhisi: bu makinenin Vision'da hangi dilleri desteklediğini logla — "tr-TR yok" gibi bir
    // ortam farkı bir sonraki kırmızıda saniyeler içinde teşhis edilsin (bkz. dosya üstü CI notu).
    let supportedLanguages = (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []
    print(
      "Tur9Tests: Vision desteklenen diller (\(supportedLanguages.count)): \(supportedLanguages)")
    print("Tur9Tests: tr-TR destekleniyor mu: \(supportedLanguages.contains("tr-TR"))")

    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("taranmis-tr.pdf")
    Self.makeScannedTurkishFixture(to: source)
    let info = PDFFileInfo.inspect(source)

    let outcome = try await OCROperation().run(
      file: info, context: OperationContext(outputDirectory: dir)) { _ in }
    guard case .produced(let outputs, let note) = outcome, let output = outputs.first else {
      return XCTFail("çıktı üretilmedi: \(outcome)")
    }
    XCTAssertEqual(output.lastPathComponent, "taranmis-tr_ocr.txt")

    let text = try String(contentsOf: output, encoding: .utf8)
    // Kanıt 1: sayfa ayracı var.
    XCTAssertTrue(text.contains("--- sayfa 1 ---"), "sayfa ayracı yok: \(text)")
    // Kanıt 2: kelimelerin KENDİSİ doğru okunmuş — aksan farkına karşı normalize edilerek (bkz.
    // dosya üstü CI notu: aksanlar bir ortamda düşse bile kelimenin kendisi doğru okunuyor).
    XCTAssertTrue(normalizedTurkishContains(text, "MARŞI"), "MARŞI okunamadı: \(text)")
    XCTAssertTrue(normalizedTurkishContains(text, "ÖRNEK"), "ÖRNEK okunamadı: \(text)")
    XCTAssertTrue(normalizedTurkishContains(text, "düşünce"), "düşünce okunamadı: \(text)")
    XCTAssertTrue(normalizedTurkishContains(text, "güç"), "güç okunamadı: \(text)")
    XCTAssertTrue(
      normalizedTurkishContains(text, "İSTİKLAL"), "İSTİKLAL okunamadı: \(text)")
    // Kanıt 3: not, sayfa/satır/güven bilgisi ve Türkçe İ/I uyarısını içeriyor.
    guard let note else { return XCTFail("not boş") }
    XCTAssertTrue(note.contains("1 sayfa"), "not sayfa sayısını içermiyor: \(note)")
    XCTAssertTrue(note.localizedCaseInsensitiveContains("güven"), "not güven bilgisi içermiyor: \(note)")
    XCTAssertTrue(note.contains("İ"), "Türkçe İ/I uyarısı yok: \(note)")
    // Kanıt 4 (tutarlılık): üretim kodunun KENDİ bozukluk teşhisi ile notta gösterilen uyarı
    // birbirini tutmalı — CI'da tr-TR yokken bu testin sessizce yanlış geçmesini önleyen asıl
    // gate: teşhis "bozuk" diyorsa uyarı ORADA olmalı, "sağlıklı" diyorsa GEREKSİZ yere olmamalı.
    let degraded = OCRVerification.turkishSupportDegraded(level: .accurate, recognizedText: text)
    if degraded {
      XCTAssertTrue(
        note.contains(OCROperation.turkishSupportWarning),
        "Türkçe desteği bozuk teşhis edildi ama notta uyarı YOK: \(note)")
    } else {
      XCTAssertFalse(
        note.contains(OCROperation.turkishSupportWarning),
        "Türkçe desteği sağlıklı teşhis edildi ama uyarı GEREKSİZ yere notta: \(note)")
    }
  }

  // MARK: - 1b. OCR: aksanların BİREBİR doğru okunduğu (yalnız tr-TR destekleniyorsa)

  /// `testOCRRecognizesTurkishTextFromScannedFixture` normalize ederek "kelime doğru mu" sorusunu
  /// her ortamda sınıyor — bu test AYRICA "aksanlar BİREBİR doğru mu" sorusunu, yalnızca bu
  /// makinede Vision'ın `tr-TR` dil varlıkları GERÇEKTEN kuruluyken sınar. Kurulu değilse (bkz.
  /// dosya üstü CI notu — `macos-15` runner'da tam bu durum ölçüldü) `XCTSkip` ile atlanır: aksan
  /// doğruluğu yalnızca dil GERÇEKTEN destekleniyorken anlamlı bir iddia.
  func testOCRTurkishDiacriticsAreCorrectWhenLanguageSupported() async throws {
    let supportedLanguages = (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []
    print(
      "Tur9Tests (aksan testi): Vision desteklenen diller (\(supportedLanguages.count)): "
        + "\(supportedLanguages)")
    guard supportedLanguages.contains("tr-TR") else {
      throw XCTSkip(
        "Bu makinede Vision tr-TR dil desteği yok (desteklenenler: \(supportedLanguages)) — "
          + "aksan doğruluğu yalnızca tr-TR GERÇEKTEN destekleniyorken sınanabilir.")
    }

    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("taranmis-tr-aksan.pdf")
    Self.makeScannedTurkishFixture(to: source)
    let outcome = try await OCROperation().run(
      file: PDFFileInfo.inspect(source), context: OperationContext(outputDirectory: dir)) { _ in }
    guard case .produced(let outputs, let note) = outcome, let output = outputs.first else {
      return XCTFail("çıktı üretilmedi: \(outcome)")
    }
    let text = try String(contentsOf: output, encoding: .utf8)

    // tr-TR GERÇEKTEN destekleniyorken aksanlar BİREBİR (normalize ETMEDEN) doğru okunmalı. İ/I
    // hatası (bkz. `OCRVerification` dosya üstü yorumu) dil desteğinden BAĞIMSIZ, AYRI ölçülmüş
    // bir kusur — bu yüzden yalnız İSTİKLAL'de İ/I toleranslı, diğer aksanlarda (Ş/ğ/ü/ç/ı) KESİN.
    XCTAssertTrue(text.contains("MARŞI"), "Ş aksanı kayboldu: \(text)")
    XCTAssertTrue(text.contains("ÖRNEK"), "Ö aksanı kayboldu: \(text)")
    XCTAssertTrue(text.contains("öğüt"), "ğ/ü aksanı kayboldu: \(text)")
    XCTAssertTrue(text.contains("düşünce"), "ş/ü aksanı kayboldu: \(text)")
    XCTAssertTrue(text.contains("çiçek"), "ç aksanı kayboldu: \(text)")
    XCTAssertTrue(text.contains("ığdır"), "ı/ğ aksanı kayboldu: \(text)")
    XCTAssertTrue(text.contains("güç"), "ü/ç aksanı kayboldu: \(text)")
    let istiklalTolerant = text.replacingOccurrences(of: "İ", with: "I").contains("ISTIKLAL")
    XCTAssertTrue(istiklalTolerant, "İSTİKLAL (İ/I toleranslı) okunamadı: \(text)")

    // tr-TR GERÇEKTEN destekleniyor ve aksanlar doğru okunduğu için "dil desteği yok" uyarısı
    // BURADA görünmemeli.
    if let note {
      XCTAssertFalse(
        note.contains(OCROperation.turkishSupportWarning),
        "tr-TR desteklenirken 'dil desteği yok' uyarısı YANLIŞLIKLA tetiklendi: \(note)")
    }
  }

  // MARK: - 2. OCR: metin katmanı olan dosyada uyarı

  func testOCRWarnsWhenFileAlreadyHasTextLayer() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("metinli.pdf")
    Self.makeVectorTextFixture(text: "Zaten metin katmanli sayfa", to: source)
    let outcome = try await OCROperation().run(
      file: PDFFileInfo.inspect(source), context: OperationContext(outputDirectory: dir)) { _ in }
    guard case .produced(_, let note) = outcome, let note else {
      return XCTFail("çıktı/not üretilmedi: \(outcome)")
    }
    XCTAssertTrue(note.contains("zaten metin katmanı var"), "metin katmanı uyarısı yok: \(note)")
  }

  // MARK: - 3. OCR: boş/beyaz sayfada skip + taranan sayfa sayısı

  func testOCRSkipsBlankPagesAndReportsScannedCount() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("bos.pdf")
    Self.makeBlankFixture(pageCount: 3, to: source)
    let outcome = try await OCROperation().run(
      file: PDFFileInfo.inspect(source), context: OperationContext(outputDirectory: dir)) { _ in }
    XCTAssertEqual(outcome, .skipped(reason: "Metin tanınamadı (3 sayfa tarandı)"))
  }

  // MARK: - 4. Aranabilir PDF: PDFKit ile metin çıkarılabiliyor

  func testSearchablePDFTextIsExtractableWithPDFKit() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("taranmis.pdf")
    Self.makeScannedTurkishFixture(to: source)
    // Ön koşul: kaynağın GERÇEKTEN metin katmanı yok (taranmış benzetimi doğru kuruldu mu) —
    // yoksa test 4 asıl kanıtı OCR'dan değil kaynaktaki gizli bir metinden alıyor olabilir.
    XCTAssertFalse(OCRVerification.hasExistingTextLayer(at: source), "fixture'da metin katmanı VAR")

    let outcome = try await SearchablePDFOperation().run(
      file: PDFFileInfo.inspect(source), context: OperationContext(outputDirectory: dir)) { _ in }
    guard case .produced(let outputs, _) = outcome, let output = outputs.first else {
      return XCTFail("çıktı üretilmedi: \(outcome)")
    }
    XCTAssertEqual(output.lastPathComponent, "taranmis_aranabilir.pdf")

    // Asıl kanıt: PDFKit ile açılan çıktının 1. sayfasında OCR'ın bulduğu belirgin bir kelime
    // GERÇEKTEN var (`page.string` ile — annotation/metadata değil, gerçek metin içeriği). Aksana
    // karşı normalize edilerek karşılaştırılıyor — `testOCRRecognizesTurkishTextFromScannedFixture`
    // dosya üstü CI notundaki AYNI kök neden (bir makinede tr-TR yoksa aksanlar düşebilir) burada
    // da geçerli; sinyal kaybetmeden ortama dayanıklı hale getirildi.
    guard let outputDoc = PDFDocument(url: output), let outputPage = outputDoc.page(at: 0),
      let extractedText = outputPage.string
    else { return XCTFail("çıktı PDFKit ile açılamadı") }
    XCTAssertTrue(
      normalizedTurkishContains(extractedText, "MARŞI")
        || normalizedTurkishContains(extractedText, "ÖRNEK"),
      "çıktıda ne MARŞI ne ÖRNEK PDFKit ile bulunabildi: \(extractedText)")
  }

  // MARK: - 5. Aranabilir PDF: çıktı GÖRSEL olarak kaynakla aynı

  func testSearchablePDFIsVisuallyIdenticalToSource() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("taranmis-gorsel.pdf")
    Self.makeScannedTurkishFixture(to: source)

    let outcome = try await SearchablePDFOperation().run(
      file: PDFFileInfo.inspect(source), context: OperationContext(outputDirectory: dir)) { _ in }
    guard case .produced(let outputs, _) = outcome, let output = outputs.first else {
      return XCTFail("çıktı üretilmedi: \(outcome)")
    }

    guard let sourceDoc = CGPDFDocument(source as CFURL), let sourcePage = sourceDoc.page(at: 1),
      let outputDoc = CGPDFDocument(output as CFURL), let outputPage = outputDoc.page(at: 1)
    else { return XCTFail("sayfalar açılamadı") }

    guard let diff = OCRVerification.averagePixelDifference(pageA: sourcePage, pageB: outputPage)
    else { return XCTFail("render karşılaştırması yapılamadı") }
    // Görünmez metin GERÇEKTEN görüntüyü değiştirmemeli — eşik çok küçük (bkz. görev tanımı: "fark
    // eşiği çok küçük olmalı"). Mutasyon kanıtı (görünmez çizim atlanınca bu testin DEĞİL, test 4'ün
    // kırmızı verdiği) raporda anlatılıyor — bkz. bu testin ve `testSearchablePDFTextIsExtractable-
    // WithPDFKit`'in birbirinden BAĞIMSIZ iki farklı gerçek kanıt (görsel + metinsel) olması.
    XCTAssertLessThan(diff, 0.005, "çıktı kaynaktan görsel olarak farklı: ortalama fark \(diff)")
  }
}
