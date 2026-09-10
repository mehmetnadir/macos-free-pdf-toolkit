import CoreGraphics
import XCTest

@testable import PDFToolsCore

/// KAYIPSIZ kesim (varsayılan kip) ve onu koruyan dört kapı. Hepsi 2026-09-10'daki saha
/// arızasından doğdu: eski varsayılan motor sayfaları yeniden çiziyordu, çıktı Preview'da açılıyor
/// ve eski tek kapı "temiz" diyordu — ama xref'i kırıktı (katı okuyucular reddediyordu), renk
/// uzayları dönüşmüştü ve XMP üstverisi silinmişti. Her test, kapının BOZULDUĞUNDA kırmızıya
/// döndüğünü de gösteriyor (mutasyon), yoksa kapı olduğunu kanıtlamış olmayız.
final class LosslessTrimTests: XCTestCase {
  override func setUp() {
    super.setUp()
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    EngineLocator.extraDirectories = [repoRoot.appendingPathComponent("vendor/bin")]
  }

  private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdftools-lossless-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// Kesim paylı çok sayfalı fixture. `bleedPages` kümesindeki sayfalar TrimBox taşır, diğerleri
  /// TAŞIMAZ — "kesim payı yalnız bazı sayfalarda" durumunu da ölçebilmek için (o dosyalarda
  /// tek sayfaya bakan bir kapı sessizce yanılıyor).
  private static func makeFixture(
    to url: URL, pageCount: Int = 3, bleedPages: Set<Int>? = nil, bleed: CGFloat = 20
  ) {
    let mediaBox = CGRect(x: 0, y: 0, width: 200, height: 300)
    guard let consumer = CGDataConsumer(url: url as CFURL) else { return }
    var box = mediaBox
    guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
    for page in 1...pageCount {
      var info: [CFString: Any] = [:]
      if bleedPages?.contains(page) ?? true {
        var trimBox = mediaBox.insetBy(dx: bleed, dy: bleed)
        info[kCGPDFContextTrimBox] = Data(bytes: &trimBox, count: MemoryLayout<CGRect>.size) as CFData
      }
      context.beginPDFPage(info as CFDictionary)
      context.setFillColor(CGColor(gray: 1, alpha: 1))
      context.fill(mediaBox)
      // Kesim payına TAŞAN içerik: kesim çizgisinin dışında kalan bir şerit.
      context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: mediaBox.width, height: bleed / 2))
      // Kesim içinde kalan içerik: her sayfada farklı yerde bir kare (sayfa karışması yakalanır).
      context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
      context.fill(CGRect(x: 40, y: 40 + CGFloat(page) * 20, width: 60, height: 60))
      context.endPDFPage()
    }
    context.closePDF()
  }

  private func trim(_ source: URL, mode: String, into directory: URL) async throws -> URL {
    let outcome = try await TrimOperation().run(
      file: PDFFileInfo.inspect(source),
      context: OperationContext(
        outputDirectory: directory, options: [TrimOperation.outsideOptionID: mode])
    ) { _ in }
    guard case .produced(let urls, _) = outcome, let output = urls.first else {
      throw XCTSkip("Kesim çıktı üretmedi: \(outcome)")
    }
    return output
  }

  // MARK: - Kayıpsız kip

  /// Ana sözleşme: sayfa kesim çizgisine küçülür, kesim payı bildirimi kalkar, İÇERİK aynı kalır.
  func testLosslessTrimResizesPagesAndKeepsContent() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kaynak.pdf")
    Self.makeFixture(to: source)
    let output = try await trim(source, mode: TrimOperation.keepOutside, into: dir)

    let document = try XCTUnwrap(CGPDFDocument(output as CFURL))
    XCTAssertEqual(document.numberOfPages, 3)
    for index in 1...3 {
      let page = try XCTUnwrap(document.page(at: index))
      let media = page.getBoxRect(.mediaBox)
      XCTAssertEqual(media.width, 160, accuracy: 0.5, "sayfa \(index) genişliği kesim ölçüsü değil")
      XCTAssertEqual(media.height, 260, accuracy: 0.5, "sayfa \(index) yüksekliği kesim ölçüsü değil")
      XCTAssertFalse(
        QPDFTrimEngine.boxesDiffer(page.getBoxRect(.trimBox), media),
        "sayfa \(index) hâlâ kesim payı bildiriyor — kullanıcı işlemi ikinci kez uygulanabilir görür")
    }
    // Kesim payı bildirimi kalktığı için dosya artık "kesilecek bir şeyi olmayan" dosya:
    XCTAssertNil(PDFFileInfo.inspect(output).trimBox)
  }

  /// Kayıpsız kip DOSYAYI YENİDEN YAZMAZ: envanter (görüntü/renk uzayı/font/XMP/sürüm) birebir.
  /// Bu, kullanıcının gözle gördüğü hasarın (renk ve çizgi kaymaları) ölçülebilir karşılığı.
  func testLosslessTrimDoesNotRewriteContent() async throws {
    let qpdf = try XCTUnwrap(EngineLocator.find("qpdf"))
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kaynak.pdf")
    Self.makeFixture(to: source)
    let before = try await PDFContentInventory.read(source, qpdf: qpdf)
    let output = try await trim(source, mode: TrimOperation.keepOutside, into: dir)
    let after = try await PDFContentInventory.read(output, qpdf: qpdf)

    XCTAssertEqual(after.differences(from: before), [], "kayıpsız kipte içerik değişmemeli")
    XCTAssertEqual(after.colorSpaces, before.colorSpaces)
    XCTAssertGreaterThanOrEqual(
      PDFContentInventory.versionValue(after.pdfVersion),
      PDFContentInventory.versionValue(before.pdfVersion), "PDF sürümü düşürülmüş")
  }

  /// Çıktının İSKELETİ sağlam: `qpdf --check` sıfır kırık offset. Saha arızasının doğrudan ölçüsü.
  func testLosslessTrimOutputHasSoundStructure() async throws {
    let qpdf = try XCTUnwrap(EngineLocator.find("qpdf"))
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kaynak.pdf")
    Self.makeFixture(to: source)
    let output = try await trim(source, mode: TrimOperation.keepOutside, into: dir)

    let structure = try await PDFStructureCheck.inspect(output, qpdf: qpdf)
    XCTAssertTrue(structure.isSound, "çıktı yapısal olarak bozuk: \(structure.summary)")
    XCTAssertEqual(structure.brokenOffsets, 0)
  }

  /// Kesim payı YALNIZ BAZI sayfalarda olan dosyada, payı olmayan sayfa OLDUĞU GİBİ kalır.
  func testPagesWithoutBleedAreLeftAlone() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kismi.pdf")
    Self.makeFixture(to: source, pageCount: 3, bleedPages: [1, 3])
    let output = try await trim(source, mode: TrimOperation.keepOutside, into: dir)

    let document = try XCTUnwrap(CGPDFDocument(output as CFURL))
    let trimmed = try XCTUnwrap(document.page(at: 1)).getBoxRect(.mediaBox)
    let untouched = try XCTUnwrap(document.page(at: 2)).getBoxRect(.mediaBox)
    XCTAssertEqual(trimmed.width, 160, accuracy: 0.5)
    XCTAssertEqual(untouched.width, 200, accuracy: 0.5, "kesim payı olmayan sayfa da küçültülmüş")
  }

  // MARK: - Kırpma kipi (varsayılan): kayıpsız AMA kesim dışı içerik çizilemez

  /// İKİ TARAFLI KANIT, tek testte: aynı fixture'ı iki kipte kesiyoruz.
  /// · "clip" → bant TEMİZ olmalı (kesim çizgisi dışında hiçbir şey çizilmiyor)
  /// · "keep" → bant DOLU olmalı (içerik bilerek duruyor)
  /// İkinci yarı, bant kapısının körleşmediğinin kanıtı: kapı her şeye "temiz" diyorsa
  /// birinci yarı da anlamsızdır. (Fixture kesim payına taşan kırmızı bir şerit çiziyor.)
  func testClipModeRemovesWhatIsOutsideAndKeepModeDoesNot() async throws {
    let qpdf = try XCTUnwrap(EngineLocator.find("qpdf"))
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kaynak.pdf")
    Self.makeFixture(to: source)

    let clipped = try await trim(source, mode: TrimOperation.clipOutside, into: dir)
    let clippedBand = try await TrimVerification.residue(in: clipped, source: source, qpdf: qpdf)
    XCTAssertEqual(
      clippedBand.verdict, .clean,
      "kırpma kipinde kutu dışında mürekkep kaldı: %\(clippedBand.residuePercent)")

    let kept = try await trim(source, mode: TrimOperation.keepOutside, into: dir)
    let keptBand = try await TrimVerification.residue(in: kept, source: source, qpdf: qpdf)
    XCTAssertEqual(
      keptBand.verdict, .failed,
      "'kalsın' kipinde bant temiz göründü — bant kapısı ölçmüyor demektir (%\(keptBand.residuePercent))")
  }

  /// Kırpma KAYIPSIZ: içerik akışına iki yeni akış ekleniyor, var olan hiçbir bayt
  /// değişmiyor — envanter birebir, kesim İÇİNDEKİ piksel birebir.
  func testClipModeIsLossless() async throws {
    let qpdf = try XCTUnwrap(EngineLocator.find("qpdf"))
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kaynak.pdf")
    Self.makeFixture(to: source)
    let before = try await PDFContentInventory.read(source, qpdf: qpdf)

    let output = try await trim(source, mode: TrimOperation.clipOutside, into: dir)
    let after = try await PDFContentInventory.read(output, qpdf: qpdf)
    XCTAssertEqual(after.differences(from: before), [], "kırpma içeriği değiştirdi")
    XCTAssertTrue(
      TrimVerification.fidelity(source: source, output: output).isFaithful,
      "kesim içindeki içerik kırpmadan sonra farklı render ediliyor")
  }

  /// KENAR YUMUŞATMA PAYI kapıyı körleştirmedi: kesim payı DURAN bir dosyada bant hâlâ
  /// "failed". Pay (0,5 pt) gerçek kesim payından (fixture'da 20 pt) çok küçük.
  func testAntialiasGuardDoesNotBlindTheBandGate() async throws {
    let qpdf = try XCTUnwrap(EngineLocator.find("qpdf"))
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kaynak.pdf")
    Self.makeFixture(to: source)
    // "Kalsın" kipiyle kesilmiş dosya: kutusu kesim ölçüsünde AMA kesim payı içeriği yerinde.
    // Bant kapısı bunu kalıntılı görmek ZORUNDA — kapının kör olduğu durum tam buydu.
    let kept = try await trim(source, mode: TrimOperation.keepOutside, into: dir)
    XCTAssertGreaterThan(
      TrimVerification.antialiasGuardPoints, 0, "pay sıfırsa bu testin konusu yok")
    let band = try await TrimVerification.residue(in: kept, source: source, qpdf: qpdf)
    XCTAssertEqual(
      band.verdict, .failed,
      "kenar yumuşatma payı kapıyı körleştirdi: kalıntı %\(band.residuePercent)")
  }

  // MARK: - Kapıların MUTASYONLA kanıtı

  /// GEOMETRİ KAPISI: hiç kesilmemiş bir dosya çıktı olarak verilirse kapı kırmızıya dönmeli.
  /// (Kapının gerçekten ölçtüğünü gösteren mutasyon; yeşil kalırsa kapı süs demektir.)
  func testGeometryGateRejectsAnUntrimmedOutput() throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kaynak.pdf")
    let copy = dir.appendingPathComponent("kopya.pdf")
    Self.makeFixture(to: source)
    try FileManager.default.copyItem(at: source, to: copy)

    let geometry = TrimVerification.geometry(source: source, output: copy)
    XCTAssertFalse(geometry.isCorrect)
    XCTAssertEqual(geometry.firstMismatch, 1)
    XCTAssertEqual(geometry.pagesStillDeclaringBleed, 3, "kesilmemiş dosya hâlâ kesim payı bildirir")
  }

  /// GEOMETRİ KAPISI her sayfaya bakıyor mu: yalnız 3. sayfası kesilmemiş bir çıktı üretip
  /// kapının o sayfayı işaret etmesini bekliyoruz. İlk sayfaya bakan bir kapı bunu KAÇIRIR.
  func testGeometryGateChecksEveryPageNotJustTheFirst() throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kaynak.pdf")
    let output = dir.appendingPathComponent("yarim.pdf")
    Self.makeFixture(to: source)
    // 1. ve 2. sayfası kesilmiş, 3. sayfası kesilmemiş bir "çıktı" elle kuruluyor.
    Self.makeMixedOutput(to: output, trimmedPages: [1, 2], pageCount: 3)

    let geometry = TrimVerification.geometry(source: source, output: output)
    XCTAssertEqual(geometry.checkedPages, 3)
    XCTAssertEqual(geometry.firstMismatch, 3)
  }

  /// SADAKAT KAPISI: doğru ölçüde ama BOŞ sayfalar üreten bir "çıktı" reddedilmeli. Kesim payını
  /// atan ama içeriği de silen bir motor tam böyle bir dosya üretir ve geometri kapısı bunu görmez.
  func testFidelityGateRejectsBlankPages() throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kaynak.pdf")
    let blank = dir.appendingPathComponent("bos.pdf")
    Self.makeFixture(to: source)
    Self.makeBlank(to: blank, size: CGSize(width: 160, height: 260), pageCount: 3)

    let fidelity = TrimVerification.fidelity(source: source, output: blank)
    XCTAssertFalse(fidelity.isFaithful, "boş sayfa sadık sayıldı — kapı ölçmüyor")
    XCTAssertGreaterThan(fidelity.differingPixelPercent, TrimVerification.faithfulPercent)
  }

  /// SADAKAT KAPISI doğru olan çıktıda yeşil kalmalı (yanlış alarm üretmiyor).
  func testFidelityGateAcceptsTheLosslessOutput() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("kaynak.pdf")
    Self.makeFixture(to: source)
    let output = try await trim(source, mode: TrimOperation.keepOutside, into: dir)

    let fidelity = TrimVerification.fidelity(source: source, output: output)
    XCTAssertTrue(
      fidelity.isFaithful,
      "kayıpsız çıktı sadık bulunmadı (%\(fidelity.differingPixelPercent)) — yanlış alarm")
  }

  /// YAPI KAPISI: qpdf'in "offset 0" uyarısı sayılıyor, kendi ikilimizin JPEG kütüphane gürültüsü
  /// SAYILMIYOR. İkisi de gerçek çıktılardan alınmış satırlar.
  func testStructureGateCountsBrokenOffsetsAndIgnoresOurJPEGNoise() {
    let broken = """
      checking out.pdf
      WARNING: out.pdf (object 18 0): object has offset 0 - a common error handled correctly by qpdf
      WARNING: out.pdf (object 85 0): object has offset 0 - a common error handled correctly by qpdf
      """
    let result = PDFStructureCheck.parse(output: broken, status: 3)
    XCTAssertEqual(result.brokenOffsets, 2)
    XCTAssertFalse(result.isSound)

    let noise = """
      checking out.pdf
      WARNING: out.pdf (offset 2463677): error decoding stream data for object 3364 0: Wrong JPEG library version: library is 62, caller expects 80
      WARNING: out.pdf (offset 2463677): stream will be re-processed without filtering to avoid data loss
      """
    XCTAssertTrue(
      PDFStructureCheck.parse(output: noise, status: 3).isSound,
      "kendi qpdf ikilimizin JPEG uyarısı dosyayı suçluyor — JPEG içeren her sağlam PDF reddedilir")
    XCTAssertFalse(
      PDFStructureCheck.parse(output: "checking out.pdf\n", status: 2).isSound,
      "qpdf hata koduyla döndüğünde ayrıştırılabilir satır olmasa da sağlam denmemeli")
  }

  /// ENVANTER KAPISI: yeniden çizmenin gerçek imzası (gri görüntülerin ICC'ye dönmesi, XMP kaybı,
  /// sürüm düşmesi) fark olarak bildirilmeli. Değerler gerçek ölçümden alınmıştır.
  func testInventoryGateReportsRedrawDamage() {
    let source = PDFContentInventory(
      pdfVersion: "1.4", imageCount: 117, colorSpaces: ["/DeviceGray": 86, "/Indexed": 28],
      metadataStreams: 7, embeddedFonts: 23, annotations: 4)
    let redrawn = PDFContentInventory(
      pdfVersion: "1.3", imageCount: 117, colorSpaces: ["/ICCBased": 57, "/DeviceGray": 30, "/Indexed": 28],
      metadataStreams: 0, embeddedFonts: 23, annotations: 0)
    let differences = redrawn.differences(from: source)
    XCTAssertTrue(differences.contains { $0.contains("colour spaces") }, "\(differences)")
    XCTAssertTrue(differences.contains { $0.contains("metadata") }, "\(differences)")
    XCTAssertTrue(differences.contains { $0.contains("annotations") }, "\(differences)")
    XCTAssertTrue(differences.contains { $0.contains("version lowered") }, "\(differences)")
    XCTAssertEqual(source.differences(from: source), [], "aynı envanter fark üretmemeli")
  }

  /// MOTOR SEÇİMİ SÖZLEŞMESİ. Bu testin sebebi: sentetik fixture'lar yeniden çizme hasarını
  /// ÜRETEMİYOR (ölçüldü — CoreGraphics kendi ürettiği dosyayı birebir koruyor; hasar yalnız
  /// gerçek matbaa dosyalarında, ICC etiketli JPEG / DeviceN / XMP taşıyanlarda çıkıyor). Yani
  /// "testler yeşil" varsayılanın yanlış motora dönmesini ENGELLEMEZ. Kararı doğrudan bu test
  /// çiviliyor.
  ///
  /// Gerçek dosyayla doğrulama (telifli olduğu için depoya girmez, elle koşulur):
  ///   ./.build/debug/pdftools trim --out /tmp/x <kesim-paylı.pdf>
  ///   vendor/bin/qpdf --check /tmp/x/<ad>_trimmed.pdf | grep -c "offset 0"   # 0 olmalı
  func testKeepModeNeverFallsBackToARewritingEngine() {
    let qpdf = URL(fileURLWithPath: "/bin/qpdf")
    let gs = URL(fileURLWithPath: "/bin/gs")

    // Kayıpsız kipler: açıklama olsa da, gs kurulu olsa da qpdf kullanılır. Fark yalnız
    // kırpmanın uygulanıp uygulanmadığı.
    XCTAssertEqual(
      TrimOperation.engineChoice(
        mode: TrimOperation.keepOutside, annotationCount: 12, qpdf: qpdf, ghostscript: gs),
      .lossless(qpdf, .boxesOnly))
    XCTAssertEqual(
      TrimOperation.engineChoice(
        mode: TrimOperation.clipOutside, annotationCount: 12, qpdf: qpdf, ghostscript: gs),
      .lossless(qpdf, .clipOutside))
    // qpdf yoksa SESSİZCE yeniden yazan motora düşmek YASAK — kullanıcıya söylenir.
    XCTAssertEqual(
      TrimOperation.engineChoice(
        mode: TrimOperation.keepOutside, annotationCount: 0, qpdf: nil, ghostscript: gs),
      .qpdfMissing)
    // Tanınmayan kip değeri kayıpsız + kırpma sayılır: yanlış yazım hasara yol açamaz.
    XCTAssertEqual(
      TrimOperation.engineChoice(
        mode: "hatalı-değer", annotationCount: 0, qpdf: qpdf, ghostscript: gs),
      .lossless(qpdf, .clipOutside))

    // Silme kipi: açıklama varsa gs (bağlantıları korur), yoksa/gs kurulu değilse CoreGraphics.
    XCTAssertEqual(
      TrimOperation.engineChoice(
        mode: TrimOperation.removeOutside, annotationCount: 3, qpdf: qpdf, ghostscript: gs),
      .ghostscript(gs))
    XCTAssertEqual(
      TrimOperation.engineChoice(
        mode: TrimOperation.removeOutside, annotationCount: 3, qpdf: qpdf, ghostscript: nil),
      .coreGraphics)
    XCTAssertEqual(
      TrimOperation.engineChoice(
        mode: TrimOperation.removeOutside, annotationCount: 0, qpdf: qpdf, ghostscript: gs),
      .coreGraphics)
  }

  // MARK: - Fixture yardımcıları

  /// Bazı sayfaları kesilmiş, bazıları kesilmemiş bir dosya (kapı mutasyonu için).
  private static func makeMixedOutput(to url: URL, trimmedPages: Set<Int>, pageCount: Int) {
    let full = CGRect(x: 0, y: 0, width: 200, height: 300)
    let cut = CGRect(x: 0, y: 0, width: 160, height: 260)
    guard let consumer = CGDataConsumer(url: url as CFURL) else { return }
    var documentBox = cut
    guard let context = CGContext(consumer: consumer, mediaBox: &documentBox, nil) else { return }
    for page in 1...pageCount {
      var box = trimmedPages.contains(page) ? cut : full
      let data = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
      context.beginPDFPage([kCGPDFContextMediaBox: data as CFData] as CFDictionary)
      context.setFillColor(CGColor(gray: 1, alpha: 1))
      context.fill(box)
      context.endPDFPage()
    }
    context.closePDF()
  }

  private static func makeBlank(to url: URL, size: CGSize, pageCount: Int) {
    guard let consumer = CGDataConsumer(url: url as CFURL) else { return }
    var box = CGRect(origin: .zero, size: size)
    guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
    for _ in 1...pageCount {
      let data = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
      context.beginPDFPage([kCGPDFContextMediaBox: data as CFData] as CFDictionary)
      context.setFillColor(CGColor(gray: 1, alpha: 1))
      context.fill(box)
      context.endPDFPage()
    }
    context.closePDF()
  }
}
