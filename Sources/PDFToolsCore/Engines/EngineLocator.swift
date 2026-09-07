import Foundation

/// Motor ikililerini bulur. Arama sırası:
/// 1. `extraDirectories` (testler / programatik)
/// 2. `PDFTOOLS_BIN_DIR` ortam değişkeni
/// 3. Uygulama paketi: `Contents/Resources/bin`
/// 4. Geliştirme: çalıştırılabilirden yukarı doğru `vendor/bin`
/// 5. Homebrew yolları
public enum EngineLocator {
  nonisolated(unsafe) public static var extraDirectories: [URL] = []

  public static func searchDirectories() -> [URL] {
    var dirs = extraDirectories
    if let env = ProcessInfo.processInfo.environment["PDFTOOLS_BIN_DIR"], !env.isEmpty {
      dirs.append(URL(fileURLWithPath: env))
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

  public static func trimEngine() -> (any TrimEngine)? {
    for dir in gsSearchDirectories() {
      let candidate = dir.appendingPathComponent("gs")
      if FileManager.default.isExecutableFile(atPath: candidate.path) {
        return GhostscriptEngine(executable: candidate)
      }
    }
    return nil
  }
}
