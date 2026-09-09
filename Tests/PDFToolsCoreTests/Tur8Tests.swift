import CoreGraphics
import XCTest

@testable import PDFToolsCore

/// Tur 8 — "Filigran Kaldır" (DENEYSEL) için testler. Gerçek kitap (telifli) teste KONMADI;
/// bunun yerine ÇOK SAYFALI, SAYFALAR ARASI PAYLAŞILAN bir Form XObject içeren minimal bir PDF
/// EL İLE (ham bayt düzeyinde, `PDFFixtureBuilder` ile) üretiliyor. CoreGraphics/PDFKit'in genel
/// PDF yazma API'leri (`CGContext.beginPDFPage` vb.) sayfalar arasında GERÇEK bir paylaşılan
/// Form XObject nesnesi (aynı indirect reference) üretecek bir yol sunmuyor — her çağrı kendi
/// içeriğini yazıyor, nesne paylaşımı yok. Bu yüzden xref tablosu dahil ham PDF baytları
/// elle yazıldı (bkz. `PDFFixtureBuilder`); bu, gerçek kitaptaki "144 sayfanın 143'ünde AYNI
/// nesne (`1507 0`)" durumunu birebir simüle etmenin TEK yolu.
final class Tur8Tests: XCTestCase {
  static let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  override class func setUp() {
    super.setUp()
    EngineLocator.extraDirectories = [repoRoot.appendingPathComponent("vendor/bin")]
  }

  private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdftools-watermark-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }

  private var qpdfURL: URL {
    guard let url = EngineLocator.find("qpdf") else { fatalError("qpdf bulunamadı — vendor/bin eksik") }
    return url
  }

  // MARK: - Ham PDF bayt üretici

  /// Minimal, elle yazılmış (xref tablosu dahil) bir PDF üretir. `--json`/`CGPDFDocument`'in
  /// anlayabileceği en yalın biçim: düz (sıkıştırılmamış) akışlar, tek nesil (generation 0),
  /// klasik (cross-reference STREAM değil, tablo) xref.
  private final class PDFFixtureBuilder {
    private var data = Data()
    private var offsets: [Int: Int] = [:]
    private var nextNumber = 1

    init() {
      data.append(Data("%PDF-1.4\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8))
    }

    /// Yeni bir nesne numarası ayırır (henüz YAZILMAZ — `writeObject`/`writeStreamObject` ile
    /// sırayla ya da daha sonra yazılabilir; xref yalnızca yazma anındaki ofsete bakar).
    func reserve() -> Int {
      defer { nextNumber += 1 }
      return nextNumber
    }

    func writeObject(_ number: Int, _ body: String) {
      offsets[number] = data.count
      data.append(Data("\(number) 0 obj\n\(body)\nendobj\n".utf8))
    }

    func writeStreamObject(_ number: Int, dict: String, body: String) {
      let bodyData = Data(body.utf8)
      offsets[number] = data.count
      data.append(Data("\(number) 0 obj\n<< \(dict) /Length \(bodyData.count) >>\nstream\n".utf8))
      data.append(bodyData)
      data.append(Data("\nendstream\nendobj\n".utf8))
    }

    /// xref tablosunu + trailer'ı ekleyip son PDF baytlarını döner. Her xref satırı TAM 20 bayt
    /// olmalı (PDF spesifikasyonu) — format `"%010d 00000 n \n"` bunu sağlıyor (10+1+5+1+1+1+1=20).
    func finish(root: Int) -> Data {
      let maxObject = nextNumber - 1
      let xrefOffset = data.count
      var xref = "xref\n0 \(maxObject + 1)\n0000000000 65535 f \n"
      for n in 1...maxObject {
        xref += String(format: "%010d 00000 n \n", offsets[n] ?? 0)
      }
      xref += "trailer\n<< /Size \(maxObject + 1) /Root \(root) 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
      data.append(Data(xref.utf8))
      return data
    }
  }

  /// Sayfa boyutu (300×400) ve filigran BBox'ı (footer şeridi) tüm fixture'larda SABİT — testler
  /// arasında karşılaştırılabilir olsun diye.
  private static let pageSize = CGSize(width: 300, height: 400)
  private static let watermarkBBox = CGRect(x: 20, y: 5, width: 260, height: 20)
  private static let watermarkText = "ORNEK-FILIGRAN"

  /// `pageCount` sayfalık bir PDF üretir. `watermarkPages` filigranın bulunacağı sayfa
  /// İNDEKSLERİ (0 tabanlı, `nil` ise HEPSİ). `sharedForm` false ise her sayfa KENDİ (paylaşılmayan)
  /// Form XObject nesnesini kullanır — "aynı görünen ama aslında paylaşılmayan nesne" negatif
  /// senaryosunu simüle eder (gerçek tespit yalnızca NESNE KİMLİĞİNE bakar, görsel benzerliğe değil).
  ///
  /// `indirectResources`: true ise sayfanın `/Resources`'ı VE onun içindeki `/XObject`'i,
  /// gömülü sözlük yerine AYRI nesnelere yazılıp DOLAYLI REFERANSLA (`"N 0 R"`) bağlanır — gerçek
  /// kitapta (bkz. saha ölçümü, 592,9 MB / 144 sayfa) HER İKİSİ de böyle çıktı ve ilk sürüm bunu
  /// çözemediği için sahada `candidates(in:)` hep BOŞ dönüyordu; bu parametre olmadan (varsayılan
  /// `false`, gömülü sözlük) o regresyon YAKALANAMAZDI (bkz. `testDetectsWatermarkWithIndirect
  /// ResourcesAndXObject`).
  @discardableResult
  private func writeWatermarkFixture(
    pageCount: Int, watermarkPages: Set<Int>? = nil, sharedForm: Bool = true,
    indirectResources: Bool = false, to url: URL
  ) -> (formObjectRef: String, totalPages: Int) {
    let watermarkPages = watermarkPages ?? Set(0..<pageCount)
    let builder = PDFFixtureBuilder()

    let catalogNum = builder.reserve()
    let pagesNum = builder.reserve()
    let fontNum = builder.reserve()
    let formNums: [Int] =
      sharedForm ? [builder.reserve()] : (0..<pageCount).map { _ in builder.reserve() }

    var pageNums: [Int] = []
    var contentNums: [Int] = []
    // Yalnız `indirectResources` true iken kullanılır: sayfa başına AYRI `/Resources` ve
    // `/XObject` sözlük nesneleri (gerçek kitaptaki iki katmanlı dolaylılığı taklit eder).
    var resourcesDictNums: [Int] = []
    var xobjectDictNums: [Int] = []
    for _ in 0..<pageCount {
      pageNums.append(builder.reserve())
      contentNums.append(builder.reserve())
      if indirectResources {
        resourcesDictNums.append(builder.reserve())
        xobjectDictNums.append(builder.reserve())
      }
    }

    let mediaBox = "0 0 \(Int(pageSize.width)) \(Int(pageSize.height))"
    let bbox = Self.watermarkBBox
    let bboxStr = "\(bbox.minX) \(bbox.minY) \(bbox.maxX) \(bbox.maxY)"

    builder.writeObject(
      fontNum, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")

    let formStream = "BT /F0 12 Tf 1 0 0 1 25 10 Tm (\(Self.watermarkText)) Tj ET\n"
    for fNum in formNums {
      builder.writeStreamObject(
        fNum,
        dict:
          "/Type /XObject /Subtype /Form /BBox [\(bboxStr)] /Matrix [1 0 0 1 0 0] "
          + "/Resources << /Font << /F0 \(fontNum) 0 R >> >>",
        body: formStream)
    }

    for i in 0..<pageCount {
      let hasWatermark = watermarkPages.contains(i)
      let formNumForPage = sharedForm ? formNums[0] : formNums[i]
      let xobjectEntry = hasWatermark ? "/Fm0 \(formNumForPage) 0 R" : ""

      let resourcesValue: String
      if indirectResources {
        // İki katman da AYRI nesne + dolaylı referans: sayfa -> `/Resources N 0 R` -> o nesnenin
        // KENDİSİ `/XObject M 0 R` -> o nesnenin KENDİSİ `<< /Fm0 ... >>`.
        builder.writeObject(xobjectDictNums[i], "<< \(xobjectEntry) >>")
        builder.writeObject(
          resourcesDictNums[i], "<< /XObject \(xobjectDictNums[i]) 0 R >>")
        resourcesValue = "\(resourcesDictNums[i]) 0 R"
      } else {
        resourcesValue = "<< /XObject << \(xobjectEntry) >> >>"
      }

      builder.writeObject(
        pageNums[i],
        "<< /Type /Page /Parent \(pagesNum) 0 R /MediaBox [\(mediaBox)] "
          + "/Resources \(resourcesValue) /Contents \(contentNums[i]) 0 R >>")

      // Sayfaya özgü, filigran BÖLGESİ DIŞINDA (üst kısımda) bir gri dikdörtgen — piksel
      // karşılaştırmasının "filigran dışı içerik bozulmamış" iddiasını anlamlı kılan gerçek içerik.
      let gray = 0.2 + Double(i % 5) * 0.1
      var content = "q\n" + String(format: "%.2f", gray) + " g\n40 300 200 60 re\nf\nQ\n"
      if hasWatermark {
        content += "q 1 0 0 1 0 0 cm /Fm0 Do Q\n"
      }
      builder.writeStreamObject(contentNums[i], dict: "", body: content)
    }

    let kids = pageNums.map { "\($0) 0 R" }.joined(separator: " ")
    builder.writeObject(pagesNum, "<< /Type /Pages /Kids [\(kids)] /Count \(pageCount) >>")
    builder.writeObject(catalogNum, "<< /Type /Catalog /Pages \(pagesNum) 0 R >>")

    let data = builder.finish(root: catalogNum)
    try? FileManager.default.removeItem(at: url)
    try? data.write(to: url)
    return ("\(formNums[0]) 0 R", pageCount)
  }

  private var pageSize: CGSize { Self.pageSize }

  // MARK: - 1. Tespit: tekrarlayan nesneyi buluyor mu, sayfa sayısı + metin doğru mu

  func testCandidatesDetectsRepeatingWatermarkObject() async throws {
    let dir = try makeTempDirectory()
    let url = dir.appendingPathComponent("watermarked.pdf")
    // 10 sayfa, 9'unda filigran (gerçek kitaptaki 143/144 oranını küçük ölçekte taklit eder) —
    // son sayfa (indeks 9) BİLEREK filigransız: "N-1 sayfada bulundu, hepsinde değil" senaryosu.
    writeWatermarkFixture(pageCount: 10, watermarkPages: Set(0..<9), to: url)

    let candidates = try await WatermarkRemoveOperation.candidates(in: url)
    XCTAssertEqual(candidates.count, 1, "tam olarak bir aday bulunmalıydı: \(candidates)")
    guard let candidate = candidates.first else { return }
    XCTAssertEqual(candidate.pageCount, 9)
    XCTAssertEqual(candidate.totalPageCount, 10)
    XCTAssertEqual(candidate.extractedText, Self.watermarkText)
    XCTAssertEqual(candidate.coveragePercent, 90, accuracy: 0.01)
    XCTAssertEqual(candidate.bbox.width, Self.watermarkBBox.width, accuracy: 0.01)
    XCTAssertEqual(candidate.bbox.height, Self.watermarkBBox.height, accuracy: 0.01)
    XCTAssertEqual(candidate.bbox.minX, Self.watermarkBBox.minX, accuracy: 0.01)
  }

  /// REGRESYON (saha bulgusu, 2026-09-08): gerçek 592,9 MB / 144 sayfalık kitapta bu tespit hep
  /// BOŞ dönüyordu — kanıtlandı ki sebep, sayfanın `/Resources`'ının (VE onun `/XObject`'inin)
  /// gömülü sözlük DEĞİL, `"353 0 R"` gibi DOLAYLI REFERANS olmasıydı; ilk sürüm yalnızca
  /// `as? [String: Any]` ile doğrudan cast deniyordu, dize geldiğinde sessizce nil dönüp sayfayı
  /// atlıyordu. Önceki `testCandidatesDetectsRepeatingWatermarkObject` fixture'ı `/Resources`'ı
  /// GÖMÜLÜ yazdığı için bu regresyonu YAKALAYAMIYORDU (testler yeşildi, saha kırmızıydı) — bu
  /// yüzden `indirectResources: true` ile AYRI bir fixture kullanılıyor.
  func testDetectsWatermarkWithIndirectResourcesAndXObject() async throws {
    let dir = try makeTempDirectory()
    let url = dir.appendingPathComponent("indirect-watermarked.pdf")
    writeWatermarkFixture(
      pageCount: 10, watermarkPages: Set(0..<9), indirectResources: true, to: url)

    let candidates = try await WatermarkRemoveOperation.candidates(in: url)
    XCTAssertEqual(
      candidates.count, 1,
      "dolaylı /Resources+/XObject'te aday bulunamadı — indirection çözümü bozuk: \(candidates)")
    guard let candidate = candidates.first else { return }
    XCTAssertEqual(candidate.pageCount, 9)
    XCTAssertEqual(candidate.totalPageCount, 10)
    XCTAssertEqual(candidate.extractedText, Self.watermarkText)

    // Kaldırma da uçtan uca çalışmalı (yalnız TESPİT değil).
    let info = PDFFileInfo.inspect(url)
    let outcome = try await WatermarkRemoveOperation().run(
      file: info, context: OperationContext(outputDirectory: dir)) { _ in }
    guard case .produced(let outputs, _) = outcome, let output = outputs.first else {
      return XCTFail("dolaylı fixture'da kaldırma başarısız: \(outcome)")
    }
    guard let doc = CGPDFDocument(output as CFURL) else { return XCTFail("çıktı açılamadı") }
    XCTAssertEqual(doc.numberOfPages, 10)
  }

  // MARK: - 2. Kaldırma: metin gidiyor, sayfa sayısı korunuyor

  func testRunRemovesWatermarkAndPreservesPageCount() async throws {
    let dir = try makeTempDirectory()
    let url = dir.appendingPathComponent("watermarked.pdf")
    writeWatermarkFixture(pageCount: 8, to: url)
    let info = PDFFileInfo.inspect(url)
    XCTAssertEqual(info.pageCount, 8)

    let outcome = try await WatermarkRemoveOperation().run(
      file: info, context: OperationContext(outputDirectory: dir)) { _ in }
    guard case .produced(let outputs, let note) = outcome, let output = outputs.first else {
      return XCTFail("çıktı üretilmedi: \(outcome)")
    }
    XCTAssertEqual(output.lastPathComponent, "watermarked_clean.pdf")
    XCTAssertNotNil(note)
    XCTAssertTrue(note?.contains("8 of 8") ?? false, "beklenen kapsama metni yok: \(note ?? "nil")")
    XCTAssertTrue(note?.contains(Self.watermarkText) ?? false, "metin `note`'ta yok: \(note ?? "nil")")

    guard let doc = CGPDFDocument(output as CFURL) else { return XCTFail("çıktı açılamadı") }
    XCTAssertEqual(doc.numberOfPages, 8, "sayfa sayısı korunmalıydı")

    // Kanıt: metin çıkarımı çıktı üzerinde TEKRAR çalıştırıldığında artık boş dönmeli — bu,
    // `WatermarkRemoveVerification.textReallyRemoved`'ın run() içinde zaten geçtiğini (aksi
    // halde run() hata fırlatırdı) BAĞIMSIZ bir ikinci ölçümle teyit eder.
    let afterCandidates = try await WatermarkRemoveOperation.candidates(in: output)
    if let stillListed = afterCandidates.first {
      XCTAssertTrue(
        stillListed.extractedText.isEmpty,
        "filigran metni çıktıda HÂLÂ görünüyor: '\(stillListed.extractedText)'")
    }
    // (Nesne dict'i korunduğundan — yalnız akışı boşaltıldı — obje yapısal olarak hâlâ "aday"
    // sayılabilir; asıl kanıt metnin BOŞ olması, adayın listede hiç görünmemesi DEĞİL.)
  }

  // MARK: - 3. Filigran dışı içerik piksel piksel korunmuş mu

  func testPixelsOutsideWatermarkRegionAreUnchanged() async throws {
    let dir = try makeTempDirectory()
    let url = dir.appendingPathComponent("watermarked.pdf")
    writeWatermarkFixture(pageCount: 5, to: url)
    let info = PDFFileInfo.inspect(url)

    let candidates = try await WatermarkRemoveOperation.candidates(in: url)
    guard let candidate = candidates.first else { return XCTFail("aday bulunamadı") }

    let outcome = try await WatermarkRemoveOperation().run(
      file: info, context: OperationContext(outputDirectory: dir)) { _ in }
    guard case .produced(let outputs, _) = outcome, let output = outputs.first else {
      return XCTFail("çıktı üretilmedi: \(outcome)")
    }

    let result = WatermarkRemoveVerification.verify(source: url, output: output, candidate: candidate)
    XCTAssertEqual(result.verdict, .clean, "beklenmedik piksel farkı: \(result.reason)")
  }

  // MARK: - 4. Tekrarlayan nesne yoksa `.skipped`

  func testSkippedWhenNoRepeatingObjectExists() async throws {
    let dir = try makeTempDirectory()
    let url = dir.appendingPathComponent("no-shared-object.pdf")
    // Her sayfa GÖRSEL OLARAK aynı filigranı taşıyor ama HER SAYFANIN KENDİ (paylaşılmayan)
    // Form nesnesi var — gerçek tespit yalnızca nesne KİMLİĞİNE bakar, bu yüzden aday BULUNMAMALI.
    writeWatermarkFixture(pageCount: 4, sharedForm: false, to: url)

    let candidates = try await WatermarkRemoveOperation.candidates(in: url)
    XCTAssertTrue(candidates.isEmpty, "paylaşılmayan nesnelerde aday BULUNMAMALIYDI: \(candidates)")

    let info = PDFFileInfo.inspect(url)
    let outcome = try await WatermarkRemoveOperation().run(
      file: info, context: OperationContext(outputDirectory: dir)) { _ in }
    XCTAssertEqual(outcome, .skipped(reason: "No repeating watermark found"))
  }

  // MARK: - 5. Mutasyon kanıtı: doğrulayıcı "hâlâ orada"yı gerçekten yakalıyor mu

  /// Bu test gate'in KENDİSİNİ sınar (bkz. `TrimTests.testTrimVerificationCatchesFakeTrim` ile
  /// aynı üslup): `output` olarak KAYNAĞIN KENDİSİNİ veriyoruz — filigran fiilen HİÇ silinmedi,
  /// `textReallyRemoved` bunu YAKALAYIP `false` dönmeli. Geliştirme sırasında bu fonksiyonun
  /// gövdesi geçici olarak `return true` yapılıp bu testin KIRMIZI verdiği gözlemlendi, sonra
  /// geri alınıp YEŞİLE döndüğü doğrulandı (bkz. görev raporu) — burada kalıcı regresyon testi
  /// olarak duruyor.
  func testTextReallyRemovedCatchesUnremovedWatermark() async throws {
    let dir = try makeTempDirectory()
    let url = dir.appendingPathComponent("watermarked.pdf")
    writeWatermarkFixture(pageCount: 6, to: url)

    let candidates = try await WatermarkRemoveOperation.candidates(in: url)
    guard let candidate = candidates.first else { return XCTFail("aday bulunamadı") }

    let removed = try await WatermarkRemoveVerification.textReallyRemoved(
      candidate: candidate, output: url, qpdfExecutable: qpdfURL)
    XCTAssertFalse(
      removed,
      "doğrulayıcı, filigran HÂLÂ VARKEN (kaynağın kendisini 'çıktı' olarak verdik) "
        + "'kaldırıldı' diyor — gate sahte pozitif üretiyor")
  }
}
