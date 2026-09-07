import CoreGraphics
import XCTest

@testable import PDFToolsCore

final class UnlockTests: XCTestCase {
  static let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  override class func setUp() {
    super.setUp()
    EngineLocator.extraDirectories = [repoRoot.appendingPathComponent("vendor/bin")]
  }

  private func fixture(_ name: String) -> URL {
    guard let url = Bundle.module.url(forResource: name, withExtension: "pdf", subdirectory: "Fixtures") else {
      fatalError("fixture yok: \(name)")
    }
    return url
  }

  private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdftools-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }

  private func assertUnencrypted(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
    guard let doc = CGPDFDocument(url as CFURL) else {
      return XCTFail("çıktı açılamadı: \(url.path)", file: file, line: line)
    }
    XCTAssertFalse(doc.isEncrypted, "çıktı hâlâ şifreli", file: file, line: line)
    XCTAssertEqual(doc.numberOfPages, 1, file: file, line: line)
  }

  func testInspectDetectsLockStates() {
    XCTAssertEqual(PDFFileInfo.inspect(fixture("owner-only")).lockState, .restricted)
    XCTAssertEqual(PDFFileInfo.inspect(fixture("user-locked")).lockState, .passwordRequired)
    let plain = PDFFileInfo.inspect(fixture("plain"))
    XCTAssertEqual(plain.lockState, .none)
    XCTAssertEqual(plain.pageCount, 1)
    XCTAssertGreaterThan(plain.fileSize, 0)
  }

  func testBothEnginesAreAvailable() {
    let names = EngineLocator.availableEngines().map(\.name)
    print("motorlar:", names)
    XCTAssertEqual(Set(names), ["qpdf", "pdfcpu"], "vendor/bin eksik: packaging/build-engines.sh çalıştır")
  }

  /// Regresyon: iptal edilen alt süreç sonlandırılmalı ve CancellationError dönmeli
  /// (önceki hata: terminate sonrası normal EOF, CancellationError yerine EngineError.failed).
  func testCancellationTerminatesEngineProcess() async throws {
    let dir = try makeTempDirectory()
    let marker = "pdftools-cancel-\(UUID().uuidString)"
    let script = dir.appendingPathComponent("slow-qpdf")
    try "#!/bin/sh\n# \(marker)\nsleep 30\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let engine = QPDFEngine(executable: script)
    let output = dir.appendingPathComponent("out.pdf")
    let task = Task {
      try await engine.decrypt(input: self.fixture("owner-only"), output: output, password: nil) { _ in }
    }
    try await Task.sleep(for: .milliseconds(300))
    task.cancel()
    do {
      try await task.value
      XCTFail("iptal edilen çağrı hata fırlatmalıydı")
    } catch is CancellationError {
      // beklenen
    }
    try await Task.sleep(for: .milliseconds(300))
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-f", marker]
    pgrep.standardOutput = Pipe()
    try pgrep.run()
    pgrep.waitUntilExit()
    XCTAssertEqual(pgrep.terminationStatus, 1, "alt süreç hâlâ çalışıyor (yetim kaldı)")
  }

  func testEveryEngineUnlocksRestrictedPDF() async throws {
    for engine in EngineLocator.availableEngines() {
      let dir = try makeTempDirectory()
      let context = OperationContext(outputDirectory: dir, engines: [engine])
      let outcome = try await UnlockOperation().run(
        file: PDFFileInfo.inspect(fixture("owner-only")), context: context) { _ in }
      guard case .produced(let output, _) = outcome else {
        return XCTFail("\(engine.name): çıktı üretilmedi")
      }
      XCTAssertEqual(output.lastPathComponent, "owner-only_unlocked.pdf")
      assertUnencrypted(output)
    }
  }

  func testEveryEngineUnlocksUserLockedPDFWithPassword() async throws {
    for engine in EngineLocator.availableEngines() {
      let dir = try makeTempDirectory()
      let context = OperationContext(password: "1234", outputDirectory: dir, engines: [engine])
      let outcome = try await UnlockOperation().run(
        file: PDFFileInfo.inspect(fixture("user-locked")), context: context) { _ in }
      guard case .produced(let output, _) = outcome else {
        return XCTFail("\(engine.name): çıktı üretilmedi")
      }
      assertUnencrypted(output)
    }
  }

  func testWrongPasswordFails() async throws {
    for engine in EngineLocator.availableEngines() {
      let dir = try makeTempDirectory()
      let context = OperationContext(password: "yanlış", outputDirectory: dir, engines: [engine])
      do {
        _ = try await UnlockOperation().run(
          file: PDFFileInfo.inspect(fixture("user-locked")), context: context) { _ in }
        XCTFail("\(engine.name): yanlış şifre kabul edildi")
      } catch let error as OperationError {
        XCTAssertEqual(error, .wrongPassword, "\(engine.name)")
      }
      let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
      XCTAssertTrue(leftovers.isEmpty, "\(engine.name): artık dosya kaldı: \(leftovers)")
    }
  }

  func testMissingPasswordIsReportedBeforeRunningEngine() async throws {
    let dir = try makeTempDirectory()
    do {
      _ = try await UnlockOperation().run(
        file: PDFFileInfo.inspect(fixture("user-locked")), context: OperationContext(outputDirectory: dir)) { _ in }
      XCTFail("şifresiz çalışmamalıydı")
    } catch let error as OperationError {
      XCTAssertEqual(error, .passwordRequired)
    }
  }

  func testPlainPDFIsSkipped() async throws {
    let dir = try makeTempDirectory()
    let outcome = try await UnlockOperation().run(
      file: PDFFileInfo.inspect(fixture("plain")), context: OperationContext(outputDirectory: dir)) { _ in }
    XCTAssertEqual(outcome, .skipped(reason: "Zaten kilitsiz"))
  }

  func testOutputNamingAvoidsCollisions() throws {
    let dir = try makeTempDirectory()
    let input = dir.appendingPathComponent("kitap.pdf")
    let first = OutputNaming.uniqueURL(for: input, suffix: "_unlocked")
    XCTAssertEqual(first.lastPathComponent, "kitap_unlocked.pdf")
    FileManager.default.createFile(atPath: first.path, contents: Data())
    let second = OutputNaming.uniqueURL(for: input, suffix: "_unlocked")
    XCTAssertEqual(second.lastPathComponent, "kitap_unlocked 2.pdf")
  }

  func testCollectPDFsExpandsDirectoriesAndFiltersExtensions() throws {
    let dir = try makeTempDirectory()
    for name in ["b.pdf", "a.PDF", "not.txt"] {
      FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
    }
    let found = PDFFileInfo.collectPDFs(from: [dir, dir.appendingPathComponent("not.txt")])
    XCTAssertEqual(found.map(\.lastPathComponent), ["a.PDF", "b.pdf"])
  }
}
