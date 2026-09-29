import CoreGraphics
import XCTest

@testable import PDFToolsCore

/// GÜVENLİK REGRESYONU (2026-09-29 denetimi): adı `-` ile başlayan bir dosya alt sürece ÇIPLAK
/// argüman olarak gittiğinde qpdf/pdfcpu/gs bunu bir BAYRAK sanabiliyordu — ölçüm ve gerekçe:
/// `Sources/PDFToolsCore/Engines/PDFEngine.swift` (`QPDFArgument`, `PDFCPUEngine.decrypt`) ve
/// `Sources/PDFToolsCore/Engines/GhostscriptEngine.swift`. Bu dosya düzeltmeyi (qpdf → `./` ön eki,
/// pdfcpu/gs → `--` sonlandırıcı) KALICI kılar: her motor/işlem gerçek bir "-" dosyasıyla uçtan uca
/// doğrulanıyor.
///
/// `URL(fileURLWithPath:)` HER ZAMAN mutlak bir yol üretir (`/` ile başlar) — bu yüzden pratikte
/// hiçbir çağıran bu hatayı tetiklemiyor (ölçüldü). Gerçek bir "-" ile başlayan `URL.path` üretmenin
/// tek yolu göreli bir `file:` referansı kurmak (`dashRelativeURL`); `isFileURL` yine `true` kalır ve
/// `CGPDFDocument`/`PDFKit` bunu CWD'ye göre gerçek bir dosya gibi açabiliyor (ölçüldü) — yani bu,
/// "biri ileride yanlışlıkla göreli bir URL üretirse" senaryosunu birebir taklit ediyor ve motor
/// katmanının ÇAĞIRANIN disiplinine güvenmediğini kanıtlıyor.
final class DashFilenameSafetyTests: XCTestCase {
  static let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  override class func setUp() {
    super.setUp()
    EngineLocator.extraDirectories = [repoRoot.appendingPathComponent("vendor/bin")]
  }

  private func fixture(_ name: String) -> URL {
    guard let url = Bundle.module.url(forResource: name, withExtension: "pdf", subdirectory: "Fixtures")
    else {
      fatalError("fixture yok: \(name)")
    }
    return url
  }

  private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdftools-dash-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }

  /// `-` ile başlayan, GÖRELİ bir `file:` URL'i kurar (bkz. dosya üstü yorum — `URL(fileURLWithPath:)`
  /// bunu üretemez, o yüzden bilerek `URLComponents` kullanılıyor).
  private func dashRelativeURL(name: String) -> URL {
    var components = URLComponents()
    components.scheme = "file"
    components.path = name
    guard let url = components.url else { fatalError("dash URL kurulamadı: \(name)") }
    return url
  }

  /// Gövdeyi `dir`'i CWD yaparak çalıştırır (göreli `file:` URL'lerin motor tarafında doğru
  /// çözülebilmesi için — `Process` varsayılan olarak çağıranın CWD'sini miras alır) ve sonunda ESKİ
  /// CWD'yi geri yükler.
  private func withCurrentDirectory<T>(_ dir: URL, _ body: () async throws -> T) async rethrows -> T {
    let previous = FileManager.default.currentDirectoryPath
    FileManager.default.changeCurrentDirectoryPath(dir.path)
    defer { FileManager.default.changeCurrentDirectoryPath(previous) }
    return try await body()
  }

  // MARK: - Motor katmanı

  func testQPDFEngineDecryptsDashPrefixedInputAndOutput() async throws {
    guard let qpdf = EngineLocator.find("qpdf") else { return XCTFail("qpdf yok") }
    let dir = try makeTempDirectory()
    let inputName = "-q-\(UUID().uuidString.prefix(6)).pdf"
    let outputName = "-out-\(UUID().uuidString.prefix(6)).pdf"
    let absoluteInput = dir.appendingPathComponent(inputName)
    let absoluteOutput = dir.appendingPathComponent(outputName)
    try FileManager.default.copyItem(at: fixture("plain"), to: absoluteInput)

    let engine = QPDFEngine(executable: qpdf)
    try await withCurrentDirectory(dir) {
      try await engine.decrypt(
        input: dashRelativeURL(name: inputName), output: dashRelativeURL(name: outputName),
        password: nil) { _ in }
    }

    XCTAssertTrue(FileManager.default.fileExists(atPath: absoluteOutput.path))
    XCTAssertEqual(CGPDFDocument(absoluteOutput as CFURL)?.numberOfPages, 1)
  }

  func testPDFCPUEngineDecryptsDashPrefixedInputAndOutput() async throws {
    guard let pdfcpu = EngineLocator.find("pdfcpu") else { return XCTFail("pdfcpu yok") }
    let dir = try makeTempDirectory()
    let inputName = "-cpu-\(UUID().uuidString.prefix(6)).pdf"
    let outputName = "-out-\(UUID().uuidString.prefix(6)).pdf"
    let absoluteInput = dir.appendingPathComponent(inputName)
    let absoluteOutput = dir.appendingPathComponent(outputName)
    // "owner-only": şifresiz açılır ama pdfcpu'nun gerçek bir decrypt geçişi yapması için sahip
    // şifresiyle korunmuş bir fixture gerekiyor (bkz. `UnlockTests.testEveryEngineUnlocksRestrictedPDF`
    // aynı gerekçe) — düz bir PDF'te pdfcpu "this file is not encrypted" ile hata veriyor (ölçüldü).
    try FileManager.default.copyItem(at: fixture("owner-only"), to: absoluteInput)

    let engine = PDFCPUEngine(executable: pdfcpu)
    try await withCurrentDirectory(dir) {
      try await engine.decrypt(
        input: dashRelativeURL(name: inputName), output: dashRelativeURL(name: outputName),
        password: nil) { _ in }
    }

    XCTAssertTrue(FileManager.default.fileExists(atPath: absoluteOutput.path))
    guard let doc = CGPDFDocument(absoluteOutput as CFURL) else {
      return XCTFail("çıktı açılamadı")
    }
    XCTAssertFalse(doc.isEncrypted)
  }

  func testGhostscriptEngineTrimsDashPrefixedInput() async throws {
    guard let gs = EngineLocator.ghostscript() else {
      throw XCTSkip("Ghostscript kurulu değil (brew install ghostscript)")
    }
    let dir = try makeTempDirectory()
    let inputName = "-gs-\(UUID().uuidString.prefix(6)).pdf"
    let absoluteInput = dir.appendingPathComponent(inputName)
    let absoluteOutput = dir.appendingPathComponent("out.pdf")
    try FileManager.default.copyItem(at: fixture("plain"), to: absoluteInput)

    let engine = GhostscriptEngine(executable: gs)
    try await withCurrentDirectory(dir) {
      try await engine.trim(input: dashRelativeURL(name: inputName), output: absoluteOutput) { _ in }
    }

    guard let doc = CGPDFDocument(absoluteOutput as CFURL) else {
      return XCTFail("çıktı açılamadı")
    }
    XCTAssertEqual(doc.numberOfPages, 1)
  }

  // MARK: - PDFStructureCheck (qpdf'in `--`'siz genel yol formu — bkz. `QPDFArgument` yorumu)

  func testStructureCheckInspectsDashPrefixedFile() async throws {
    guard let qpdf = EngineLocator.find("qpdf") else { return XCTFail("qpdf yok") }
    let dir = try makeTempDirectory()
    let inputName = "-chk-\(UUID().uuidString.prefix(6)).pdf"
    let absoluteInput = dir.appendingPathComponent(inputName)
    try FileManager.default.copyItem(at: fixture("plain"), to: absoluteInput)

    let result = try await withCurrentDirectory(dir) {
      try await PDFStructureCheck.inspect(dashRelativeURL(name: inputName), qpdf: qpdf)
    }
    XCTAssertTrue(result.isSound, "beklenmedik hata: \(result.summary)")
  }

  func testStructureCheckRepairsDashPrefixedFile() async throws {
    guard let qpdf = EngineLocator.find("qpdf") else { return XCTFail("qpdf yok") }
    let dir = try makeTempDirectory()
    let inputName = "-rep-\(UUID().uuidString.prefix(6)).pdf"
    let absoluteInput = dir.appendingPathComponent(inputName)
    try FileManager.default.copyItem(at: fixture("plain"), to: absoluteInput)

    try await withCurrentDirectory(dir) {
      try await PDFStructureCheck.repair(dashRelativeURL(name: inputName), qpdf: qpdf)
    }
    // `repair` dosyayı YERİNDE değiştirir (moveItem/replaceItemAt) — hâlâ geçerli bir PDF olmalı.
    XCTAssertEqual(CGPDFDocument(absoluteInput as CFURL)?.numberOfPages, 1)
  }

  // MARK: - BookmarkOperation (pdfcpu `bookmarks export` — `--` sonlandırıcı)

  func testBookmarkExportHandlesDashPrefixedInput() async throws {
    guard EngineLocator.find("pdfcpu") != nil else { return XCTFail("pdfcpu yok") }
    let dir = try makeTempDirectory()
    let inputName = "-bm-\(UUID().uuidString.prefix(6)).pdf"
    let absoluteInput = dir.appendingPathComponent(inputName)
    try FileManager.default.copyItem(at: fixture("plain"), to: absoluteInput)

    let file = PDFFileInfo(
      url: dashRelativeURL(name: inputName), fileSize: 0, pageCount: 1, lockState: .none)
    let context = OperationContext(outputDirectory: dir)
    let outcome = try await withCurrentDirectory(dir) {
      try await BookmarkOperation().run(file: file, context: context) { _ in }
    }
    // "plain.pdf" fixture'ında yer imi yok — beklenen sonuç `.skipped`, ÖNEMLİ olan pdfcpu'nun
    // `-` ile başlayan girdi adını bir BAYRAK sanıp "unknown shorthand flag" ile patlamaması.
    guard case .skipped(let reason) = outcome else {
      return XCTFail("beklenmedik sonuç: \(outcome)")
    }
    XCTAssertEqual(reason, "No bookmarks to export")
  }
}
