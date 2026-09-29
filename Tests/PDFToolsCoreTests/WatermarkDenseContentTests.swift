import CoreGraphics
import XCTest

@testable import PDFToolsCore

/// ARIZA (gerçek dosyalarla ölçüldü, 2026-09-29): `pdftools watermarkadd`, filigranı GERÇEKTEN
/// çizdiği hâlde yoğun/renkli sayfalarda (9 sayfalık bir çalışma kitabı, 376 sayfalık bir soru
/// bankası) doğrulama kapısı tarafından REDDEDİLİYOR ve çıktı SİLİNİYORDU — `WatermarkVerification`
/// dosya üstü notundaki SATÜRASYON açıklamasına bakın. `Tur7Tests.testWatermarkAddPreservesPage
/// CountAndAddsInkInRegion` yalnız BEYAZ bir fixture kullanıyor (bkz. o dosyanın MARK yorumu),
/// bu yüzden satürasyon arızasını hiç yakalamıyordu. Bu dosya, kaynağın "merkez" bölgesi ZATEN
/// çoğunlukla koyu/renkli olan bir fixture ile HEM eski piksel-eşiğinin gerçekten SATÜRE olduğunu
/// (fark eski eşiğin altında) HEM YENİ yapısal+piksel karma kapının yine de GEÇTİĞİNİ kanıtlıyor,
/// HEM DE filigran hiç çizilmediğinde (mutasyon) kapının hâlâ DÜŞTÜĞÜNÜ doğruluyor.
final class WatermarkDenseContentTests: XCTestCase {
  static let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  override class func setUp() {
    super.setUp()
    EngineLocator.extraDirectories = [repoRoot.appendingPathComponent("vendor/bin")]
  }

  override func tearDown() {
    // Testing seam'i HER durumda (fail dahil) varsayılana döndür — başka testlere sızmasın.
    WatermarkAddOperation.testingSkipTextDraw = false
    super.tearDown()
  }

  private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdftools-wm-dense-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }

  /// Gerçek bir yoğun/renkli çalışma kitabı sayfasını taklit eder: koyu renkli hücreler 1pt'lik
  /// beyaz aralıklarla döşenir (~%90 mürekkep) — tamamen düz bir renk DEĞİL (o zaman kaynak/çıktı
  /// farkı hiçbir zaman > 0 olamazdı, gerçek dosyalarda da böyle değil: en yoğun soru bankasında
  /// bile ölçülen fark tam sıfır değil, %0,03'tü — ince beyaz aralıklar filigranın kenarlarında
  /// birkaç pikseli "mürekkepli"ye çevirebiliyor).
  private static func makeDenseFixture(to url: URL, pageSize: CGFloat = 300) {
    try? FileManager.default.removeItem(at: url)
    var box = CGRect(x: 0, y: 0, width: pageSize, height: pageSize)
    guard let consumer = CGDataConsumer(url: url as CFURL) else { fatalError("CGDataConsumer") }
    guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
      fatalError("CGContext(consumer:mediaBox:auxiliaryInfo:)")
    }
    context.beginPDFPage(nil)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(box)
    let colors: [(CGFloat, CGFloat, CGFloat)] = [
      (0.05, 0.05, 0.05), (0.6, 0.05, 0.05), (0.05, 0.3, 0.55), (0.15, 0.4, 0.1), (0.5, 0.2, 0.5),
    ]
    let cell: CGFloat = 20
    let gap: CGFloat = 1
    var index = 0
    var y: CGFloat = 0
    while y < pageSize {
      var x: CGFloat = 0
      while x < pageSize {
        let c = colors[index % colors.count]
        context.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
        context.fill(CGRect(x: x, y: y, width: cell - gap, height: cell - gap))
        index += 1
        x += cell
      }
      y += cell
    }
    context.endPDFPage()
    context.closePDF()
  }

  // MARK: - 1. Pozitif: yoğun/renkli sayfada filigran GEÇMELİ (asıl arıza — bkz. dosya üstü not)

  func testWatermarkAddPassesOnDenseSaturatedContent() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("yogun.pdf")
    Self.makeDenseFixture(to: source)

    // Fixture'ın GERÇEKTEN yoğun olduğunu kanıtla — kaynağın "merkez" bölgesi zaten çoğunlukla
    // mürekkepli (gerçek dosyalarda ölçülen %88-93 aralığıyla AYNI mertebede).
    let region = WatermarkVerification.region(for: "center")
    guard let srcInk = WatermarkVerification.inkPercent(pdfAt: source, pageIndex: 1, region: region)
    else { return XCTFail("kaynak mürekkep oranı ölçülemedi") }
    XCTAssertGreaterThan(srcInk, 80, "fixture yeterince yoğun değil (kaynak mürekkep: \(srcInk)%)")

    let context = OperationContext(
      outputDirectory: dir, options: [WatermarkAddOperation.textOptionID: "GIZLI TASLAK"])
    let outcome = try await WatermarkAddOperation().run(
      file: PDFFileInfo.inspect(source), context: context) { _ in }
    guard case .produced(let outputs, _) = outcome, let output = outputs.first else {
      return XCTFail("yoğun içerikte filigran REDDEDİLDİ (asıl arıza geri geldi): \(outcome)")
    }

    // Kanıt: çıktı GERÇEKTEN diskte duruyor ve boş değil.
    XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    let size = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int ?? 0
    XCTAssertGreaterThan(size, 0, "çıktı boş")

    // Eski eşikle kıyasla: bu fixture'ın piksel farkı GERÇEKTEN eski eşiğin (%0,3) altında kalıyor
    // — yani bu test, eski TEK EKSENLİ piksel kapısıyla koşulsaydı REDDEDERDİ (asıl arızayı
    // yeniden üretiyor). Yine de > 0: gerçek dosyalarda ölçülenle aynı mertebede küçük bir kenar
    // etkisi var, tam sıfır DEĞİL.
    guard
      let delta = WatermarkVerification.delta(
        sourceURL: source, outputURL: output, pageIndex: 1, position: "center")
    else { return XCTFail("mürekkep farkı ölçülemedi") }
    XCTAssertLessThan(
      delta, WatermarkVerification.minDeltaPercent,
      "fixture eski eşiği aşıyor, satürasyon senaryosunu KANITLAMIYOR (fark: \(delta)%)")
    XCTAssertGreaterThan(delta, 0, "piksel farkı sıfır/negatif olmamalı (fark: \(delta)%)")
  }

  // MARK: - 2. Mutasyon: filigran GERÇEKTEN çizilmezse kapı HÂLÂ düşmeli (kör kapı KABUL EDİLEMEZ)

  func testWatermarkAddStillRejectsWhenTextDrawIsSkipped() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("yogun.pdf")
    Self.makeDenseFixture(to: source)

    // Kendi çizim kodumuzu BİLEREK boz: her şey aynı (döndürme, renk, alfa, sayfa sayısı) ama
    // glif GERÇEKTEN gösterilmiyor (`CTLineDraw` atlanıyor). Yapısal kapı bunu "filigran yok"
    // olarak görmeli — piksel farkı zaten neredeyse sıfır olacağından (dense fixture) İKİ eksen
    // de reddetmeli.
    WatermarkAddOperation.testingSkipTextDraw = true

    let context = OperationContext(
      outputDirectory: dir, options: [WatermarkAddOperation.textOptionID: "GIZLI TASLAK"])
    do {
      _ = try await WatermarkAddOperation().run(
        file: PDFFileInfo.inspect(source), context: context) { _ in }
      XCTFail("filigran hiç çizilmediği hâlde kapı GEÇTİ — kör kapı")
    } catch let error as WatermarkError {
      guard case .verificationFailed = error else {
        return XCTFail("beklenmeyen hata türü: \(error)")
      }
    }

    // Yarım kalmış/sızmış çıktı olmamalı — dizinde yalnız kaynağın kendisi kalmalı.
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    XCTAssertEqual(leftovers, ["yogun.pdf"], "artık/yarım dosya kaldı: \(leftovers)")
  }

  // MARK: - 3. Yapısal ayrıştırıcı: doğrudan birim testleri (tokenizer'ın kendisi)

  func testStructuralCheckDetectsTrailingCenterWatermarkBlock() {
    // `WatermarkAddOperation`'ın "center" konumunda ÜRETTİĞİ GERÇEK baytlarla (2026-09-29,
    // mid.pdf üstünde ölçülen çıktıdan alındı) birebir aynı şekil: kaynağın kendi
    // (alakasız) çizimi, sonra bizim filigranımız.
    let stream = """
      q 0 0 0 0 k 0 0 640 796 re f q 1 0 0 1 0 0 cm /Im1 Do Q \
      /Cs1 cs 0.5 0.5 0.5 sc /Gs2 gs /Gs3 gs q 0.7071068 0.7071068 -0.7071068 0.7071068 320 398 \
      cm BT 36 0 0 36 -46 0 Tm /TT1 1 Tf [ (T) 0.2 (EST) ] TJ ET Q Q
      """
    let evidence = WatermarkStructuralCheck.analyze(Array(stream.utf8))
    XCTAssertNotNil(evidence)
    XCTAssertTrue(evidence?.textWasShown ?? false)
    XCTAssertTrue(WatermarkStructuralCheck.looksLikeDiagonalRotation(evidence?.rotation))
  }

  func testStructuralCheckFindsNothingWhenTextNeverDrawn() {
    // AYNI çizim, yalnız METİN GÖSTERME KISMI hiç yazılmamış (mutasyonun ürettiği tam olarak bu).
    let stream = """
      q 0 0 0 0 k 0 0 640 796 re f q 1 0 0 1 0 0 cm /Im1 Do Q \
      /Cs1 cs 0.5 0.5 0.5 sc /Gs2 gs /Gs3 gs q 0.7071068 0.7071068 -0.7071068 0.7071068 320 398 \
      cm Q Q
      """
    let evidence = WatermarkStructuralCheck.analyze(Array(stream.utf8))
    XCTAssertNil(evidence, "hiç BT/ET yokken kanıt bulunmamalı")
  }

  func testStructuralCheckRejectsEmptyShowOperator() {
    // "BT...ET" var ama gösterilen dizge BOŞ (`()`) — gerçek bir çizim değil.
    let stream = "q Q BT 36 0 0 36 0 0 Tm /TT1 1 Tf () Tj ET"
    let evidence = WatermarkStructuralCheck.analyze(Array(stream.utf8))
    XCTAssertNotNil(evidence)
    XCTAssertFalse(evidence?.textWasShown ?? true, "boş dizge 'metin gösterildi' SAYILMAMALI")
  }

  func testStructuralCheckSkipsInlineImageBinaryWithoutCorruption() {
    // Satır içi görüntünün İKİLİ verisi rastgele "q"/"Q"/"BT" benzeri baytlar içerebilir —
    // tarayıcı bunları atlamalı, ardından gelen GERÇEK filigran bloğunu yine de bulmalı.
    var bytes: [UInt8] = Array("q BI /W 2 /H 2 /BPC 8 /CS /G ID ".utf8)
    bytes.append(contentsOf: [0x71, 0x51, 0x42, 0x54, 0x0A])  // 'q','Q','B','T', olası bozucu baytlar
    bytes.append(contentsOf: Array(" EI Q ".utf8))
    bytes.append(
      contentsOf: Array(
        "BT 36 0 0 36 0 0 Tm /TT1 1 Tf (X) Tj ET".utf8))
    let evidence = WatermarkStructuralCheck.analyze(bytes)
    XCTAssertNotNil(evidence)
    XCTAssertTrue(evidence?.textWasShown ?? false)
  }
}
