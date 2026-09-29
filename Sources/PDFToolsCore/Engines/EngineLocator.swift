import Foundation

/// Motor ikililerini bulur. Arama sırası:
/// 1. `extraDirectories` (testler / programatik)
/// 2. `PDFTOOLS_BIN_DIR` ortam değişkeni (yalnız GÜVENİLİR bir dizinse — bkz. `untrustedReason(for:)`)
/// 3. Uygulama paketi: `Contents/Resources/bin`
/// 4. Geliştirme: çalıştırılabilirden yukarı doğru `vendor/bin`
/// 5. Homebrew yolları
public enum EngineLocator {
  nonisolated(unsafe) public static var extraDirectories: [URL] = []

  /// Motor konumu ile ilgili güvenlik/görünürlük notları — en yeni en sonda. Testler bu listeyi
  /// okuyarak "sessizce dış ikili kullanıldı/reddedildi" olmadığını kanıtlar; ayrıca her not
  /// stderr'e de yazılır (CLI/log görünürlüğü — bkz. dosya üstü güvenlik notu).
  ///
  /// Gerekçe (denetim bulgusu, 2026-09-29): `PDFTOOLS_BIN_DIR` daha önce hiçbir kısıt/kayıt
  /// olmadan okunuyordu. Bu değişkeni etkileyebilen biri (paylaşılan oturum ortamı, shell
  /// profili, `launchctl setenv`) sahte bir `qpdf`/`pdfcpu` gösterip parolayı (`--password=`
  /// argümanda geçiyor) ve dosya içeriğini ele geçirebilirdi. Körlemesine `#if DEBUG` ile
  /// kapatmak ÖLÇÜLDÜ: tek gerçek bağımlılık `Formula/pdftools.rb` — Homebrew CLI dağıtımı,
  /// paket kaynağı olmadığı için Release ikilisine `PDFTOOLS_BIN_DIR=${HOMEBREW_PREFIX}/bin`
  /// sarmalıyor; kapatmak bu dağıtımı kırardı. Bunun yerine dizin GÜVENİLİRLİK denetiminden
  /// geçer: dünya-yazılabilir DEĞİL ve sahibi ya çalıştıran kullanıcı ya da root olmalı.
  nonisolated(unsafe) public private(set) static var securityNotices: [String] = []

  /// `dir` güvenilmezse reddetme gerekçesini döner, güvenilirse `nil`.
  /// Güvenli sayılan yol: kullanıcının KENDİ yazabildiği ama BAŞKASININ yazamadığı bir dizin.
  /// - Dünya-yazılabilir dizinler (`/tmp` gibi, sticky bit içerik oluşturmayı ENGELLEMEZ)
  ///   reddedilir.
  /// - Başka bir hesaba ait dizinler reddedilir (root hariç — sistem yolları için); aksi halde
  ///   saldırgan KENDİ sahip olduğu, dünya-yazılabilir OLMAYAN bir dizini paylaşılan oturum
  ///   ortamıyla (`launchctl setenv`) işaret edebilirdi.
  static func untrustedReason(for dir: URL) -> String? {
    var info = stat()
    guard stat(dir.path, &info) == 0 else { return "bulunamadı" }
    guard (info.st_mode & S_IFMT) == S_IFDIR else { return "dizin değil" }
    if info.st_mode & S_IWOTH != 0 { return "dünya-yazılabilir" }
    let euid = geteuid()
    if info.st_uid != euid && info.st_uid != 0 { return "başka bir kullanıcıya ait" }
    return nil
  }

  private static func report(_ message: String) {
    securityNotices.append(message)
    FileHandle.standardError.write(Data((message + "\n").utf8))
  }

  public static func searchDirectories() -> [URL] {
    var dirs = extraDirectories
    if let env = ProcessInfo.processInfo.environment["PDFTOOLS_BIN_DIR"], !env.isEmpty {
      let dir = URL(fileURLWithPath: env)
      if let reason = untrustedReason(for: dir) {
        report("pdftools: PDFTOOLS_BIN_DIR reddedildi (\(reason)): \(env)")
      } else {
        dirs.append(dir)
        report("pdftools: motor paket dışından yüklendi (PDFTOOLS_BIN_DIR): \(env)")
      }
    }
    if let resources = Bundle.main.resourceURL {
      dirs.append(resources.appendingPathComponent("bin"))
    }
    #if DEBUG
    // Geliştirme (.build/debug) ve testler: yukarı doğru vendor/bin, sonra Homebrew.
    // Release'de kapalı: kullanıcı şifresi argümanla geçildiğinden yalnızca paketteki ikiliye güvenilir.
    var cursor = Bundle.main.executableURL?.deletingLastPathComponent()
    for _ in 0..<8 {
      guard let dir = cursor else { break }
      dirs.append(dir.appendingPathComponent("vendor/bin"))
      cursor = dir.path == "/" ? nil : dir.deletingLastPathComponent()
    }
    dirs += ["/opt/homebrew/bin", "/usr/local/bin"].map { URL(fileURLWithPath: $0) }
    #endif
    return dirs
  }

  public static func find(_ name: String) -> URL? {
    for dir in searchDirectories() {
      let candidate = dir.appendingPathComponent(name)
      if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    return nil
  }

  /// Tercih sırasına göre mevcut motorlar: qpdf (aslına sadık) → pdfcpu (yedek).
  public static func availableEngines() -> [any PDFEngine] {
    var engines: [any PDFEngine] = []
    if let qpdf = find("qpdf") { engines.append(QPDFEngine(executable: qpdf)) }
    if let pdfcpu = find("pdfcpu") { engines.append(PDFCPUEngine(executable: pdfcpu)) }
    return engines
  }

  /// `gs` (Ghostscript) için AYRI arama listesi — yukarıdaki `searchDirectories()`'ten bilinçli
  /// olarak farklı: gs asla pakete gömülmez (bkz. GhostscriptEngine.swift lisans notu), o yüzden
  /// `Contents/Resources/bin` ve `vendor/bin` aranmaz; yalnızca test override'ı
  /// (`extraDirectories`) ve Homebrew yolları kontrol edilir. Bu liste `#if DEBUG` ile SINIRLI
  /// DEĞİLDİR — Release derlemede de kullanıcının sisteminde kurulu gs bulunabilmelidir, çünkü
  /// paketin içinde hiç gs yoktur (paketteki motorlar için geçerli "yalnız Release'de
  /// bundle'dan ara" kısıtı burada anlamsızdır).
  private static func gsSearchDirectories() -> [URL] {
    extraDirectories + ["/opt/homebrew/bin", "/usr/local/bin"].map { URL(fileURLWithPath: $0) }
  }

  /// Kesim için VARSAYILAN motor: KAYIPSIZ kutu kesimi (qpdf) — sayfayı yeniden çizmez, dosyanın
  /// yapısına dokunmaz (gerekçe ve ölçümler: `QPDFTrimEngine.swift` dosya üstü yorumu).
  ///
  /// qpdf pakette GELİR; bulunamaması bir kurulum arızasıdır. Bu yüzden burada sessizce
  /// yeniden-yazan motora DÜŞMÜYORUZ: eski sürümde varsayılan `CoreGraphicsTrimEngine` idi ve
  /// kullanıcı, yapısı bozulmuş (xref'i kırık) bir çıktı aldığını ancak dosyayı başka bir sisteme
  /// verdiğinde anladı. Sessiz düşürme yerine çağıran (bkz. `TrimOperation`) kullanıcıya söyler.
  public static func losslessTrimEngine() -> QPDFTrimEngine? {
    find("qpdf").map { QPDFTrimEngine(executable: $0) }
  }

  /// Sayfaları YENİDEN YAZAN kesim motoru — yalnızca kullanıcı kesim çizgisi dışındaki içeriğin
  /// dosyadan GERÇEKTEN silinmesini istediğinde (`TrimOperation`ın "remove" kipi). İki motorun da
  /// bedeli var, ölçüldü: gs açıklamaları (bağlantı/form alanı) KORUR ama içeriği daha fazla
  /// oynatır; CoreGraphics kurulum gerektirmez ve daha sadık çizer ama açıklamaları KAYBEDER.
  /// Bu yüzden tercih dosyaya göre yapılır (bkz. çağıranın açıklama sayımı).
  public static func rewriteTrimEngine(preferGhostscript: Bool) -> any TrimEngine {
    if preferGhostscript, let gs = ghostscript() { return GhostscriptEngine(executable: gs) }
    return CoreGraphicsTrimEngine()
  }

  /// Ghostscript ikilisinin KENDİ yolu — yalnızca `gs`'i doğrudan bir alt-süreç olarak çalıştırmak
  /// isteyen çağıranlar için (ör. `CompressOperation`). `trimEngine()`'den BİLEREK AYRI: o artık
  /// kesim MOTOR TERCİHİNİ (CoreGraphics) döndürüyor, ham gs ikili yolunu değil. gs kurulu
  /// değilse `nil` — arama sırası `gsSearchDirectories()` ile aynı (yalnız test override'ı +
  /// Homebrew yolları; gs asla pakete gömülmez, bkz. `GhostscriptEngine.swift`).
  public static func ghostscript() -> URL? {
    for dir in gsSearchDirectories() {
      let candidate = dir.appendingPathComponent("gs")
      if FileManager.default.isExecutableFile(atPath: candidate.path) {
        return candidate
      }
    }
    return nil
  }
}
