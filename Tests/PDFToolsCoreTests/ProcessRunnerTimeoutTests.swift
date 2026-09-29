import Foundation
import XCTest

@testable import PDFToolsCore

/// `ProcessRunner.run`'a eklenen zaman aşımı yeteneğinin testleri (dayanıklılık düzeltmesi,
/// 2026-09-29 — asılan alt süreç GUI/CLI'ı sonsuza kadar "çalışıyor" bırakıyordu; ayrıca
/// paketlenen pdfcpu'nun eski sürümünü etkileyen bir bellek tükenmesi danışmanlığı
/// (GHSA-fjh6-rrhv-4g63) zaman aşımını salt konfor değil güvenlik tahkimatı yapıyor).
/// Üç şey kanıtlanıyor: (1) zaman aşımı GERÇEKTEN çalışıyor ve hızlı biter, (2) sonlandırılan
/// süreç zombi BIRAKMIYOR (işletim sistemine bağımsız `pgrep` ile sorulur), (3) varsayılan
/// (300 sn) zaman aşımı gerçek/meşru bir qpdf çağrısını KESMİYOR.
final class ProcessRunnerTimeoutTests: XCTestCase {
  static let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  override class func setUp() {
    super.setUp()
    EngineLocator.extraDirectories = [repoRoot.appendingPathComponent("vendor/bin")]
  }

  private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdftools-timeout-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }

  /// `sleep 619`'u `env` üzerinden, komut satırına eşsiz bir `MARKER=<uuid>` argümanı ekleyerek
  /// başlatır — bu Mac'te aynı anda başka ajanların da testleri koşabildiği paylaşılan bir
  /// ortamda `pgrep -f` ile YANLIŞLIKLA başka bir süreci yakalamamak için. `env`, argümanlarını
  /// `ps`/`pgrep -f` çıktısında olduğu gibi gösterir.
  private func hangingProcess(marker: String) -> (executable: URL, arguments: [String]) {
    (URL(fileURLWithPath: "/usr/bin/env"), ["PDFTOOLS_TEST_MARKER=\(marker)", "sleep", "619"])
  }

  private func isAlive(marker: String) throws -> Bool {
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-f", "PDFTOOLS_TEST_MARKER=\(marker)"]
    let pipe = Pipe()
    pgrep.standardOutput = pipe
    try pgrep.run()
    pgrep.waitUntilExit()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return !output.isEmpty
  }

  /// Kasten asılan bir süreç 0,5 sn'lik kısa bir zaman aşımıyla koşulur. Test, `sleep`'in kendi
  /// süresi olan 619 sn'yi DEĞİL, zaman aşımını beklediğini kanıtlamak için 5 sn'nin ALTINDA
  /// bitmeli ve `ProcessTimeoutError` fırlatmalı.
  func testTimeoutInterruptsHangingProcessQuickly() async throws {
    let marker = UUID().uuidString
    let (executable, arguments) = hangingProcess(marker: marker)
    let start = Date()
    do {
      _ = try await ProcessRunner.run(executable, arguments: arguments, timeout: 0.5)
      XCTFail("zaman aşımı fırlatmadı")
    } catch let error as ProcessTimeoutError {
      XCTAssertEqual(error.seconds, 0.5)
    } catch {
      XCTFail("beklenen ProcessTimeoutError, gelen: \(error)")
    }
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertLessThan(elapsed, 5.0, "zaman aşımı 5 sn'nin altında bitmeli, sürdü: \(elapsed) sn")
    print("[ProcessRunnerTimeoutTests] zaman aşımı testinin gerçek süresi: \(elapsed) sn")
  }

  /// Zaman aşımı sonrası asılan süreç GERÇEKTEN ölmüş mü? `ProcessRunner`'ın kendi durumuna değil,
  /// işletim sistemine (`pgrep`) bağımsız olarak sorulur — zombi/artık süreç bırakılmamalı.
  func testTimeoutLeavesNoZombieProcess() async throws {
    let marker = UUID().uuidString
    let (executable, arguments) = hangingProcess(marker: marker)
    do {
      _ = try await ProcessRunner.run(executable, arguments: arguments, timeout: 0.5)
      XCTFail("zaman aşımı fırlatmadı")
    } catch is ProcessTimeoutError {
      // beklenen
    }
    // İşletim sisteminin süreci tamamen temizlemesi için küçük bir pay.
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertFalse(try isAlive(marker: marker), "zaman aşımı sonrası süreç hâlâ yaşıyor (zombi)")
  }

  /// Meşru bir iş — paket içi GERÇEK qpdf ile gerçek bir PDF üzerinde `--check` — VARSAYILAN
  /// zaman aşımıyla (300 sn) sorunsuz tamamlanmalı. Ölçülen en yavaş gerçek koşu (376 sayfalık
  /// dosyada Ghostscript, 28,74 sn) 300 sn tavanının ~%10'u; bu test `timeout` parametresini HİÇ
  /// vermeyerek üretim kodundaki gerçek varsayılanı sınıyor.
  func testDefaultTimeoutDoesNotInterruptRealWork() async throws {
    guard let qpdf = EngineLocator.find("qpdf") else {
      return XCTFail("qpdf bulunamadı (vendor/bin?)")
    }
    let dir = try makeTempDirectory()
    let input = dir.appendingPathComponent("real.pdf")
    try BlankPDF.create(pageCount: 50, size: .a4, at: input)

    let result = try await ProcessRunner.run(qpdf, arguments: ["--check", input.path])
    XCTAssertTrue(
      result.status == 0 || result.status == 3,
      "gerçek qpdf çağrısı varsayılan zaman aşımıyla başarısız oldu: \(result.status) \(result.stderr)"
    )
  }
}
