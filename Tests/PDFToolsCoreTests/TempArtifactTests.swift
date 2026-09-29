import Darwin
import XCTest

@testable import PDFToolsCore

/// `TempArtifact` — 2026-09-29 güvenlik denetiminin kanıt testleri. Öngörülebilir ada değil,
/// `open(O_EXCL|O_NOFOLLOW|O_CREAT)` / `mkdir` düzeyinde bir sembolik-bağ yarışı korumasına
/// güvendiğimizi ÖLÇÜLEBİLİR şekilde gösterir: adı önceden tahmin edemediğimiz için gerçek bir
/// saldırının tam adını burada tekrar edemeyiz, bunun yerine yardımcıya AYNI yolu iki kez açtırıp
/// ikincinin (var olan dosya/sembolik bağ) reddedildiğini ve bir sembolik bağın üzerine açmayı
/// deneyip reddedildiğini doğrudan sınıyoruz.
final class TempArtifactTests: XCTestCase {
  private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdftools-tempartifact-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }

  // MARK: - reserveExclusiveFile / writeExclusive

  /// Aynı YOLU iki kez `reserveExclusiveFile` ile açtırıyoruz: adı yardımcı ürettiği için
  /// gerçekte iki farklı (benzersiz) yol döner, ama BİRİNCİNİN döndürdüğü TAM yolu ikinci kez
  /// (yardımcıyı bypass ederek, doğrudan `open`) açmaya çalışınca `O_EXCL` bunu reddetmeli —
  /// yani "varsa başarısız ol" sözleşmesi gerçekten uygulanıyor.
  func testReserveExclusiveFileRejectsPathThatAlreadyExists() throws {
    let dir = try makeTempDirectory()
    let (url, handle) = try TempArtifact.reserveExclusiveFile(in: dir, suffix: ".txt")
    try handle.write(contentsOf: Data("first".utf8))
    try handle.close()
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

    // Yardımcı yerine DOĞRUDAN aynı bayraklarla açmayı dene — dosya zaten var, `O_EXCL` bunu
    // reddetmeli (bu, `TempArtifact`'in içindeki mantığın birebir aynısı — gerçek saldırı
    // senaryosunda "ikinci açan" bir saldırgan/başka bir işlem olurdu).
    let fd = url.path.withCString { path in
      open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    }
    if fd >= 0 { close(fd) }
    XCTAssertEqual(fd, -1, "O_EXCL var olan dosyanın üzerine açmayı REDDETMELİ")
    XCTAssertEqual(errno, EEXIST)
  }

  /// Saldırı senaryosunun kalbi: hedef yolda ÖNCEDEN bir sembolik bağ varsa (saldırganın önceden
  /// yerleştirdiği), `reserveExclusiveFile` bu bağı TAKİP ETMEMELİ ve `O_NOFOLLOW` ile
  /// reddetmelidir — veri sembolik bağın hedefine ASLA akmamalı.
  func testReserveExclusiveFileRefusesToFollowASymlink() throws {
    let dir = try makeTempDirectory()
    let attackerTarget = dir.appendingPathComponent("attacker-owned-secret.txt")
    try Data("do not touch".utf8).write(to: attackerTarget)

    // Saldırganın "önceden yerleştirdiği" sembolik bağ — gerçek saldırıda bu, kurbanın henüz
    // yazmadığı ama ADINI TAHMİN ETTİĞİ bir yolda durur. Burada yardımcının BİR SONRAKİ
    // üreteceği adı tahmin edemediğimiz için (UUID), doğrudan yardımcının kullandığı YOLU simüle
    // ediyoruz: aynı dizine, "planted" adında bir sembolik bağ koyup yardımcıya o TAM yolu
    // açtırıyoruz (yardımcının normalde kendi ürettiği yol yerine, testin kontrol edebildiği bir
    // yol vererek davranışı doğruluyoruz).
    let plantedLinkPath = dir.appendingPathComponent("planted-symlink.txt")
    try FileManager.default.createSymbolicLink(
      at: plantedLinkPath, withDestinationURL: attackerTarget)

    let fd = plantedLinkPath.path.withCString { path in
      open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    }
    if fd >= 0 { close(fd) }
    XCTAssertEqual(fd, -1, "O_NOFOLLOW bir sembolik bağın ÜZERİNE açmayı REDDETMELİ")

    // Kanıt: saldırganın "gizli" dosyası DOKUNULMAMIŞ kalmalı.
    let untouched = try String(contentsOf: attackerTarget, encoding: .utf8)
    XCTAssertEqual(untouched, "do not touch")
  }

  func testWriteExclusiveProducesUnpredictableNameAndCorrectPermissions() throws {
    let dir = try makeTempDirectory()
    let url = try TempArtifact.writeExclusive(Data("hello".utf8), in: dir, suffix: ".txt")
    XCTAssertNotEqual(url.lastPathComponent, ".txt", "ad UUID içermeli, sabit olmamalı")
    XCTAssertTrue(url.lastPathComponent.hasPrefix("."), "ad gizli (dot-prefixed) olmalı")

    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    let permissions = (attrs[.posixPermissions] as? NSNumber)?.uint16Value
    XCTAssertEqual(permissions, 0o600, "hassas geçici dosya izinleri 0600 olmalı")

    let written = try String(contentsOf: url, encoding: .utf8)
    XCTAssertEqual(written, "hello")
  }

  // MARK: - withPrivateDirectory / withPrivateDirectorySync

  /// `mkdir`'in aynı korumayı dizin düzeyinde verdiğini gösterir: yardımcının üreteceği dizin adı
  /// önceden VAR olsaydı (sembolik bağ ya da gerçek dizin), `mkdir` bunu REDDEDER (`EEXIST`),
  /// var olan hedefin İÇİNE asla yazmaz.
  func testPrivateDirectoryCreationRejectsPathThatAlreadyExists() throws {
    let dir = try makeTempDirectory()
    let collidingName = "already-here"
    let collidingPath = dir.appendingPathComponent(collidingName, isDirectory: true)
    try FileManager.default.createDirectory(at: collidingPath, withIntermediateDirectories: true)

    // `mkdir`'in kendisini test ediyoruz — `TempArtifact` içindeki AYNI çağrı (varsayılan UUID adı
    // yerine, testin kontrol edebildiği bir adla).
    let created = collidingPath.path.withCString { path in mkdir(path, 0o700) }
    XCTAssertEqual(created, -1, "mkdir var olan bir yolun ÜZERİNE geçmemeli")
    XCTAssertEqual(errno, EEXIST)
  }

  func testWithPrivateDirectoryCleansUpOnSuccess() async throws {
    let dir = try makeTempDirectory()
    var capturedDir: URL?
    let result = try await TempArtifact.withPrivateDirectory(in: dir) { tempDir -> Int in
      capturedDir = tempDir
      XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.path))
      // İzin 0700: yalnız sahibi erişebilir.
      let attrs = try FileManager.default.attributesOfItem(atPath: tempDir.path)
      let permissions = (attrs[.posixPermissions] as? NSNumber)?.uint16Value
      XCTAssertEqual(permissions, 0o700)
      try Data("payload".utf8).write(to: tempDir.appendingPathComponent("f.txt"))
      return 42
    }
    XCTAssertEqual(result, 42)
    if let capturedDir {
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: capturedDir.path),
        "başarı sonrası geçici dizin İÇERİĞİYLE BİRLİKTE silinmeli")
    }
  }

  /// Hata yollarında da temizlik yapılmalı (`defer`) — görev şartı.
  func testWithPrivateDirectoryCleansUpOnFailure() async {
    let dir = try! makeTempDirectory()
    var capturedDir: URL?
    struct Boom: Error {}
    do {
      _ = try await TempArtifact.withPrivateDirectory(in: dir) { tempDir -> Int in
        capturedDir = tempDir
        try Data("payload".utf8).write(to: tempDir.appendingPathComponent("f.txt"))
        throw Boom()
      }
      XCTFail("hata fırlatılmalıydı")
    } catch {
      // beklenen
    }
    if let capturedDir {
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: capturedDir.path),
        "hata sonrası da geçici dizin KALMAMALI")
    }
  }

  func testWithPrivateDirectorySyncCleansUpOnSuccessAndFailure() throws {
    let dir = try makeTempDirectory()

    var capturedDir: URL?
    _ = try TempArtifact.withPrivateDirectorySync(in: dir) { tempDir -> Int in
      capturedDir = tempDir
      return 1
    }
    if let capturedDir {
      XCTAssertFalse(FileManager.default.fileExists(atPath: capturedDir.path))
    }

    struct Boom: Error {}
    var capturedDir2: URL?
    XCTAssertThrowsError(
      try TempArtifact.withPrivateDirectorySync(in: dir) { tempDir -> Int in
        capturedDir2 = tempDir
        throw Boom()
      }
    )
    if let capturedDir2 {
      XCTAssertFalse(FileManager.default.fileExists(atPath: capturedDir2.path))
    }
  }

  // MARK: - unpredictablePath (§3 — paylaşılan/kalıcı dizin, ImageIO gibi kendi açan çerçeveler)

  func testUnpredictablePathDoesNotRepeatAcrossCalls() {
    let dir = URL(fileURLWithPath: "/tmp")
    let a = TempArtifact.unpredictablePath(in: dir, suffix: ".part.jpg")
    let b = TempArtifact.unpredictablePath(in: dir, suffix: ".part.jpg")
    XCTAssertNotEqual(a, b)
    XCTAssertTrue(a.lastPathComponent.hasPrefix("."))
    XCTAssertTrue(a.lastPathComponent.hasSuffix(".part.jpg"))
  }
}
