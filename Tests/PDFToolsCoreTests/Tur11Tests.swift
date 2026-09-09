import XCTest

@testable import PDFToolsCore

/// Tur 11 — çıktı adlandırma zinciri ve çıktı hedefi (toplu klasör / Masaüstü'ne düşme).
final class Tur11Tests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdftools-tur11-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  // MARK: - Ad zinciri

  func testSuffixIsNotChained() {
    let input = root.appendingPathComponent("kitap_compressed.pdf")
    let output = OutputNaming.uniqueURL(for: input, suffix: "_numbered")
    XCTAssertEqual(output.lastPathComponent, "kitap_numbered.pdf")
  }

  func testWholeSuffixChainIsStripped() {
    let input = root.appendingPathComponent("kitap_compressed_watermarked.pdf")
    let output = OutputNaming.uniqueURL(for: input, suffix: "_numbered")
    XCTAssertEqual(output.lastPathComponent, "kitap_numbered.pdf")
  }

  func testPlainNameStillGetsItsSuffix() {
    let input = root.appendingPathComponent("kitap.pdf")
    let output = OutputNaming.uniqueURL(for: input, suffix: "_compressed")
    XCTAssertEqual(output.lastPathComponent, "kitap_compressed.pdf")
  }

  /// Adı tamamen eritecek soyma YAPILMAZ — "_ocr.pdf" adsız bir dosyaya dönüşmemeli.
  func testStrippingNeverEmptiesTheName() {
    let input = root.appendingPathComponent("_ocr.pdf")
    let output = OutputNaming.uniqueURL(for: input, suffix: "_clean")
    XCTAssertEqual(output.lastPathComponent, "_ocr_clean.pdf")
  }

  /// Soyma ÜZERİNE YAZMAYA yol açmamalı: aynı ad varsa sayaç devreye girer.
  func testStrippedNameStillAvoidsOverwriting() throws {
    let existing = root.appendingPathComponent("kitap_numbered.pdf")
    try Data("x".utf8).write(to: existing)
    let input = root.appendingPathComponent("kitap_compressed.pdf")
    let output = OutputNaming.uniqueURL(for: input, suffix: "_numbered")
    XCTAssertEqual(output.lastPathComponent, "kitap_numbered 2.pdf")
  }

  func testDirectoryNamingStripsToo() {
    let input = root.appendingPathComponent("kitap_compressed.pdf")
    let output = OutputNaming.uniqueDirectory(for: input, suffix: "_parts")
    XCTAssertEqual(output.lastPathComponent, "kitap_parts")
  }

  // MARK: - Sözleşme: adlandırıcı TÜM işlem eklerini tanımalı

  /// Yeni bir işlem eklenip eki `OutputNaming.knownSuffixes`'e YAZILMAZSA zincirleme adlandırma
  /// o işlem için SESSİZCE çalışmaz — ad yine `..._a_b.pdf` diye uzar ve kimse fark etmez.
  /// Bu test o sessiz bozulmayı derleme/test zamanında görünür kılar.
  func testEveryOperationSuffixIsKnownToTheNamer() {
    let known = Set(OutputNaming.knownSuffixes)
    for operation in OperationRegistry.all {
      for suffix in operation.outputSuffixes where !suffix.isEmpty {
        XCTAssertTrue(
          known.contains(suffix),
          "\(operation.id) ekini \"\(suffix)\" OutputNaming.knownSuffixes tanımıyor — "
            + "zincirleme adlandırma bu işlem için sessizce çalışmaz")
      }
    }
  }

  /// Sözlükte kullanılmayan ek birikmesin: her bilinen ek gerçekten bir işleme ait olmalı.
  func testKnownSuffixesHaveNoStrayEntries() {
    let used = Set(OperationRegistry.all.flatMap(\.outputSuffixes))
    for suffix in OutputNaming.knownSuffixes {
      XCTAssertTrue(used.contains(suffix), "\(suffix) hiçbir işleme ait değil — sözlükten çıkar")
    }
  }

  // MARK: - Çıktı hedefi

  func testSingleOutputGoesNextToTheOriginalWithoutAFolder() {
    let input = root.appendingPathComponent("kitap.pdf")
    let destination = OutputPlacement.resolve(
      inputs: [input], operationTitle: "Compress", expectedTopLevelOutputs: 1)
    XCTAssertEqual(destination.directory.standardizedFileURL, root.standardizedFileURL)
    XCTAssertNil(destination.batchFolderName)
    XCTAssertFalse(destination.usedFallback)
    XCTAssertNil(destination.note)
  }

  func testSeveralOutputsGetABatchFolderNextToTheOriginal() throws {
    let inputs = (1...3).map { root.appendingPathComponent("kitap\($0).pdf") }
    let destination = OutputPlacement.resolve(
      inputs: inputs, operationTitle: "Compress", expectedTopLevelOutputs: 3)
    XCTAssertEqual(destination.batchFolderName, "PDF Tools — Compress")
    XCTAssertEqual(destination.directory.deletingLastPathComponent().standardizedFileURL,
                   root.standardizedFileURL)
    var isDirectory: ObjCBool = false
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: destination.directory.path, isDirectory: &isDirectory))
    XCTAssertTrue(isDirectory.boolValue)
  }

  func testBatchFolderNameIsMadeUniqueInsteadOfReusingAnExistingOne() throws {
    let taken = root.appendingPathComponent("PDF Tools — Compress", isDirectory: true)
    try FileManager.default.createDirectory(at: taken, withIntermediateDirectories: true)
    let inputs = (1...2).map { root.appendingPathComponent("kitap\($0).pdf") }
    let destination = OutputPlacement.resolve(
      inputs: inputs, operationTitle: "Compress", expectedTopLevelOutputs: 2)
    XCTAssertEqual(destination.batchFolderName, "PDF Tools — Compress 2")
  }

  /// Kaynak klasör salt-okunursa çıktı sessizce kaybolmaz: yedek klasöre düşer ve SÖYLER.
  func testReadOnlySourceFolderFallsBackAndSaysSo() throws {
    let readOnly = root.appendingPathComponent("kilitli", isDirectory: true)
    let fallback = root.appendingPathComponent("masaustu", isDirectory: true)
    try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: readOnly.path)
    }
    try XCTSkipIf(
      FileManager.default.isWritableFile(atPath: readOnly.path),
      "klasör salt-okunur yapılamadı (root olarak koşuluyor olabilir)")

    let destination = OutputPlacement.resolve(
      inputs: [readOnly.appendingPathComponent("kitap.pdf")], operationTitle: "Compress",
      expectedTopLevelOutputs: 1, fallbackDirectory: fallback)
    XCTAssertTrue(destination.usedFallback)
    XCTAssertEqual(destination.directory.standardizedFileURL, fallback.standardizedFileURL)
    XCTAssertNotNil(destination.note, "kullanıcıya nereye yazıldığı SÖYLENMELİ")
  }

  // MARK: - Boş toplu klasörün geri alınması

  func testEmptyBatchFolderIsDiscarded() {
    let inputs = (1...2).map { root.appendingPathComponent("kitap\($0).pdf") }
    let destination = OutputPlacement.resolve(
      inputs: inputs, operationTitle: "Compress", expectedTopLevelOutputs: 2)
    XCTAssertTrue(OutputPlacement.discardIfEmpty(destination))
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.directory.path))
  }

  func testBatchFolderWithOutputsIsKept() throws {
    let inputs = (1...2).map { root.appendingPathComponent("kitap\($0).pdf") }
    let destination = OutputPlacement.resolve(
      inputs: inputs, operationTitle: "Compress", expectedTopLevelOutputs: 2)
    try Data("x".utf8).write(to: destination.directory.appendingPathComponent("cikti.pdf"))
    XCTAssertFalse(OutputPlacement.discardIfEmpty(destination))
    XCTAssertTrue(FileManager.default.fileExists(atPath: destination.directory.path))
  }

  /// Toplu klasör AÇILMADIYSA `discardIfEmpty` kullanıcının kendi klasörüne asla dokunmamalı.
  func testDiscardNeverTouchesTheUsersOwnFolder() {
    let destination = OutputDestination(
      directory: root, batchFolderName: nil, usedFallback: false, note: nil)
    XCTAssertFalse(OutputPlacement.discardIfEmpty(destination))
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
  }
}
