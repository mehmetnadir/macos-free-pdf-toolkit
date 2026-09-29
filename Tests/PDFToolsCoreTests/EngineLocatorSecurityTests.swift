import XCTest

@testable import PDFToolsCore

/// `PDFTOOLS_BIN_DIR` denetimi (güvenlik denetimi, 2026-09-29).
///
/// Arka plan: bu ortam değişkeni önceden hiçbir kısıt olmadan okunuyordu — `#if DEBUG` kısıtı
/// YOKTU ve `find()` bulunan ikilinin kim olduğunu doğrulamıyordu. Ortamı etkileyebilen biri
/// (paylaşılan oturum ortamı, shell profili, `launchctl setenv`) sahte bir `qpdf`/`pdfcpu`
/// koyup parolayı (`--password=` argümanda geçiyor) ve dosya içeriğini ele geçirebilirdi.
///
/// Bu testler `EngineLocator.untrustedReason(for:)` ile eklenen konum kısıtını (dünya-yazılabilir
/// DEĞİL + sahibi çalıştıran kullanıcı ya da root) ve `securityNotices` ile eklenen görünürlüğü
/// (sessizce kabul/red YOK) doğrular. `PDFTOOLS_BIN_DIR` testler arasında sızmasın diye her test
/// ortam değişkenini kendi alt-süreç YOK, doğrudan `untrustedReason`/`searchDirectories` üstünden
/// ölçer; gerçek ortam değişkenini değiştirmek `ProcessInfo` üstünden mümkün olmadığından (Swift
/// Foundation'da salt-okunur), asıl kanıt `setenv`/`unsetenv` (POSIX) ile veriliyor.
final class EngineLocatorSecurityTests: XCTestCase {
  static let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  private var savedExtraDirectories: [URL] = []

  override func setUp() {
    super.setUp()
    savedExtraDirectories = EngineLocator.extraDirectories
    EngineLocator.extraDirectories = []
    unsetenv("PDFTOOLS_BIN_DIR")
  }

  override func tearDown() {
    unsetenv("PDFTOOLS_BIN_DIR")
    EngineLocator.extraDirectories = savedExtraDirectories
    super.tearDown()
  }

  private func makeTempDirectory(mode: mode_t) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdftools-enginelocator-sec-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // `createDirectory` sonucu umask'a bağlı — istenen izni AÇIKÇA sabitle.
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: dir.path)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }

  /// Sahte, çalıştırılabilir bir "qpdf" yerleştirir (gerçek qpdf'i ÇAĞIRMAZ — yalnızca
  /// `isExecutableFile` ve `find()`'ın onu ADAY olarak gördüğünü kanıtlamak için).
  private func plantFakeExecutable(named name: String, in dir: URL) throws {
    let path = dir.appendingPathComponent(name)
    let script = "#!/bin/sh\necho fake-\(name)\n"
    try script.write(to: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
  }

  // MARK: - Reddetme (kötü niyetli senaryo)

  /// Dünya-yazılabilir bir dizin (ör. paylaşılan `/tmp` altı, `0777`) — İMDİ REDDEDİLİYOR.
  func testWorldWritableDirectoryIsRejected() throws {
    let dir = try makeTempDirectory(mode: 0o777)
    try plantFakeExecutable(named: "qpdf", in: dir)

    XCTAssertEqual(EngineLocator.untrustedReason(for: dir), "dünya-yazılabilir")

    setenv("PDFTOOLS_BIN_DIR", dir.path, 1)
    defer { unsetenv("PDFTOOLS_BIN_DIR") }

    XCTAssertFalse(
      EngineLocator.searchDirectories().contains(dir),
      "dünya-yazılabilir PDFTOOLS_BIN_DIR arama listesine GİRMEMELİ")
    // Test kurulumu doğrulaması: sahte ikili gerçekten diskte çalıştırılabilir (yoksa aşağıdaki
    // red iddiası anlamsız olurdu — "zaten aday değildi" ile "reddedildi" karışırdı).
    XCTAssertTrue(
      FileManager.default.isExecutableFile(atPath: dir.appendingPathComponent("qpdf").path))
  }

  /// MUTASYON KANITI (yorum): bu test, `untrustedReason(for:)` çağrısı `searchDirectories()`'ten
  /// SÖKÜLÜRSE (eski/güvensiz davranışa dönülürse) KIRMIZI verir — yukarıdaki `contains(dir)`
  /// iddiası tam tersine döner. Düzeltme öncesi hâli elle doğrulandı: bkz. görev raporu
  /// ("mutasyon kanıtı" bölümü, `git stash` ile eski koda dönülüp aynı test koşturuldu).
  func testWorldWritableDirectoryIsReported() throws {
    let dir = try makeTempDirectory(mode: 0o777)
    setenv("PDFTOOLS_BIN_DIR", dir.path, 1)
    defer { unsetenv("PDFTOOLS_BIN_DIR") }

    _ = EngineLocator.searchDirectories()

    XCTAssertTrue(
      EngineLocator.securityNotices.contains { $0.contains("reddedildi") && $0.contains(dir.path) },
      "red GÖRÜNÜR biçimde kayda geçmeli — securityNotices: \(EngineLocator.securityNotices)")
  }

  /// Başka bir kullanıcıya ait (kendi EUID'imiz değil, root da değil) bir dizin de reddedilir.
  /// Gerçek bir başka-kullanıcı dizini test ortamında oluşturulamayacağı için sahiplik kontrolü
  /// doğrudan `stat` sonucu üstünden, kendi EUID'imizi taklit ederek DEĞİL, mantığı ayrı
  /// doğrulayan birim testiyle kapatılıyor: `untrustedReason` root-sahipli (`/usr/bin` — her Mac'te
  /// var, world-writable DEĞİL, sahibi root) bir dizinde bizim EUID'imiz root olmadığı sürece
  /// "başka bir kullanıcıya ait" DEMEMELİ (root açıkça istisna) — bu, istisnanın yalnızca root'a
  /// tanındığını, rastgele "başka kullanıcı"ya tanınmadığını dolaylı doğrular.
  func testRootOwnedSystemDirectoryIsNotRejectedForOwnership() {
    // /usr/bin: sistemde daima var, dünya-yazılabilir değil, sahibi root.
    let systemDir = URL(fileURLWithPath: "/usr/bin")
    XCTAssertNil(
      EngineLocator.untrustedReason(for: systemDir),
      "root-sahipli, dünya-yazılabilir olmayan sistem dizini güvenli sayılmalı")
  }

  // MARK: - Meşru kullanımın bozulmadığı kanıtı

  /// Kullanıcının KENDİ sahip olduğu, dünya-yazılabilir OLMAYAN bir dizin (Homebrew formülünün
  /// `PDFTOOLS_BIN_DIR=${HOMEBREW_PREFIX}/bin` sarmalamasının taklidi) KABUL EDİLİR.
  func testOwnNonWorldWritableDirectoryIsAccepted() throws {
    let dir = try makeTempDirectory(mode: 0o755)
    try plantFakeExecutable(named: "qpdf", in: dir)

    XCTAssertNil(EngineLocator.untrustedReason(for: dir))

    setenv("PDFTOOLS_BIN_DIR", dir.path, 1)
    defer { unsetenv("PDFTOOLS_BIN_DIR") }

    XCTAssertTrue(
      EngineLocator.searchDirectories().contains(dir),
      "kullanıcının kendi dizini arama listesine GİRMELİ (Homebrew CLI senaryosu)")
    XCTAssertEqual(EngineLocator.find("qpdf"), dir.appendingPathComponent("qpdf"))
  }

  /// Kabul edilen kullanım da GÖRÜNÜR — sessizce dış ikili çalıştırma YOK.
  func testAcceptedExternalDirectoryIsReported() throws {
    let dir = try makeTempDirectory(mode: 0o700)
    setenv("PDFTOOLS_BIN_DIR", dir.path, 1)
    defer { unsetenv("PDFTOOLS_BIN_DIR") }

    _ = EngineLocator.searchDirectories()

    XCTAssertTrue(
      EngineLocator.securityNotices.contains {
        $0.contains("paket dışından yüklendi") && $0.contains(dir.path)
      },
      "kabul GÖRÜNÜR biçimde kayda geçmeli — securityNotices: \(EngineLocator.securityNotices)")
  }

  /// `PDFTOOLS_BIN_DIR` boşsa/atanmamışsa davranış değişmedi — hiçbir env-kaynaklı not düşmez
  /// (DEBUG derlemesinin kendi `vendor/bin`/Homebrew araması bu testte BİLEREK dokunulmuyor,
  /// yalnız env-var'a özgü davranış ölçülüyor).
  func testMissingEnvVarAddsNoNotice() {
    let noticesBefore = EngineLocator.securityNotices.count
    _ = EngineLocator.searchDirectories()
    XCTAssertEqual(EngineLocator.securityNotices.count, noticesBefore)
  }
}
