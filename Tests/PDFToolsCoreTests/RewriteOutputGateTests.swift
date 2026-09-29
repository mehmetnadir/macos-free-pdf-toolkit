import XCTest

@testable import PDFToolsCore

/// `RewriteOutput.finish`'in KAPI davranışını çivileyen testler.
///
/// NEDEN VAR (2026-09-29, bağımsız inceleme bulgusu): `finish` içerik envanterini `try?` ile
/// okuyordu ve okuma başarısız olduğunda `Report(changes: [])` ile SESSİZCE dönüyordu — yani
/// altındaki sayfa-sayısı kapısı hiç çalışmıyordu. Kendi sayfa kontrolü olmayan işlemlerde
/// (`SearchablePDFOperation`, `QRAddOperation`) eksik sayfalı çıktı bu delikten geri sızabilirdi.
///
/// Ölçüm yöntemi: gerçek qpdf'i saran bir SAHTE motor enjekte edilir (`EngineLocator.extraDirectories`).
/// Sahte motor yalnız istenen alt komutu düşürür, gerisini gerçek qpdf'e devreder — böylece
/// "envanter okunamadı ama sayfa sayısı okunabiliyor" ve "ikisi de okunamıyor" durumları
/// DETERMİNİSTİK olarak üretilebilir (gerçek bir bozuk dosya beklemeye gerek kalmaz).
final class RewriteOutputGateTests: XCTestCase {
  private var savedExtraDirectories: [URL] = []
  private var tempDir: URL!

  private static let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  private static var realQPDF: URL { repoRoot.appendingPathComponent("vendor/bin/qpdf") }

  override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipUnless(
      FileManager.default.isExecutableFile(atPath: Self.realQPDF.path),
      "paket içi qpdf yok (vendor/bin) — bu test gerçek motoru sarmalıyor")
    savedExtraDirectories = EngineLocator.extraDirectories
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdftools-rewrite-gate-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDown() {
    EngineLocator.extraDirectories = savedExtraDirectories
    if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    super.tearDown()
  }

  /// Verilen alt komut desenlerinde çöken, gerisini gerçek qpdf'e devreden bir sahte motor kurar
  /// ve arama yoluna EN BAŞA koyar.
  private func installStubQPDF(failingPatterns: [String]) throws {
    let dir = tempDir.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // `case` desenleri `|` ile ayrılır; `)` ile ayırmak betiği sözdizimi hatasına düşürür ve
    // stub HER çağrıda 2 ile çıkar (ölçüldü: o hâlde `--check` de düşüyor ve test yanlış hata alır).
    let conditions = failingPatterns.map { "*\($0)*" }.joined(separator: "|") + ")"
    let script = """
      #!/bin/sh
      for arg in "$@"; do
        case "$arg" in
          \(conditions) echo "stub: bilerek düşürüldü ($arg)" >&2; exit 2;;
        esac
      done
      exec "\(Self.realQPDF.path)" "$@"
      """
    let stub = dir.appendingPathComponent("qpdf")
    try script.write(to: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
    EngineLocator.extraDirectories = [dir]
    XCTAssertEqual(EngineLocator.find("qpdf"), stub, "sahte motor arama yolunun başında olmalı")
  }

  private func makePDF(pages: Int, name: String) throws -> URL {
    let url = tempDir.appendingPathComponent(name)
    try BlankPDF.create(pageCount: pages, size: .a4, at: url)
    return url
  }

  /// Envanter okunamıyor ama sayfa sayısı okunabiliyor VE sayfalar eşit → kapı geçer, ama
  /// "ölçemedim" durumu kullanıcıya UYARI olarak görünür (sessiz boş rapor DEĞİL).
  func testInventoryUnreadableStillVerifiesPageCountAndWarns() async throws {
    let source = try makePDF(pages: 3, name: "source.pdf")
    let output = try makePDF(pages: 3, name: "output.pdf")
    try installStubQPDF(failingPatterns: ["--json"])

    let report = try await RewriteOutput.finish(output: output, source: source)

    XCTAssertTrue(report.changes.isEmpty)
    XCTAssertFalse(
      report.warnings.isEmpty,
      "envanter ölçülemediğinde bu durum RAPORLANMALI — sessiz boş rapor fail-open'dır")
    XCTAssertEqual(
      report.note, "content inventory could not be compared (page count verified)",
      "uyarı kullanıcıya görünen nota düşmeli")
  }

  /// Envanter okunamıyor VE sayfa sayısı GERÇEKTEN düşmüş → kapı DÜŞMELİ. Bulgunun özü buydu:
  /// eski kod bu durumda sessizce başarı raporluyordu.
  func testInventoryUnreadableStillCatchesLostPages() async throws {
    let source = try makePDF(pages: 5, name: "source5.pdf")
    let output = try makePDF(pages: 4, name: "output4.pdf")
    try installStubQPDF(failingPatterns: ["--json"])

    do {
      _ = try await RewriteOutput.finish(output: output, source: source)
      XCTFail("sayfa kaybı envanter okunamasa da YAKALANMALI")
    } catch let error as OperationError {
      guard case .redrawLostPages(let before, let after) = error else {
        return XCTFail("beklenen hata redrawLostPages, gelen: \(error)")
      }
      XCTAssertEqual(before, 5)
      XCTAssertEqual(after, 4)
    }
  }

  /// Ne envanter ne sayfa sayısı ölçülebiliyor → "doğrulanamadı" diye FIRLATIR; "sorun yok"
  /// demez. ("Ölçemedim" ile "temiz" ayrı şeylerdir.)
  func testUnverifiablePageIntegrityThrows() async throws {
    let source = try makePDF(pages: 2, name: "source2.pdf")
    let output = try makePDF(pages: 2, name: "output2.pdf")
    try installStubQPDF(failingPatterns: ["--json", "--show-npages"])

    do {
      _ = try await RewriteOutput.finish(output: output, source: source)
      XCTFail("hiçbir ölçüm yapılamadığında kapı GEÇMEMELİ")
    } catch let error as OperationError {
      guard case .pageIntegrityUnverifiable = error else {
        return XCTFail("beklenen hata pageIntegrityUnverifiable, gelen: \(error)")
      }
    }
  }
}
