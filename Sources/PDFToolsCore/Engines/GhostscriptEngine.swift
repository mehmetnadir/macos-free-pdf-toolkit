import Foundation

/// Sayfa geometrisini kalıcı olarak değiştiren motor sözleşmesi (örn. kesim payı atma).
/// `PDFEngine`'den bilinçli olarak ayrı: decrypt şifre parametresi alır, trim almaz —
/// tek bir protokolde birleştirmek çağıranları anlamsız parametrelerle uğraştırırdı.
public protocol TrimEngine: Sendable {
  var name: String { get }
  var executable: URL { get }
  /// `input`'u kesip `output`'a yazar. `progress` motor destekliyorsa çağrılır (gs satır satır
  /// ilerleme raporlamaz; burada yalnızca 0→1 uç noktaları için ayrılmış bir kanca).
  func trim(
    input: URL, output: URL,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws
}

/// Ghostscript sarmalayıcısı — `gs -dUseTrimBox` ile TrimBox'ı yeni MediaBox yapar.
///
/// NEDEN GÖMÜLMEZ: Ghostscript AGPL-3.0-or-later; bu depo MIT ve paketlediğimiz qpdf/pdfcpu
/// Apache-2.0'dır. Ghostscript'i `vendor/bin`'e derleyip app bundle'a koymak dağıtımın
/// lisansını fiilen AGPL'e çeker (kaynak sunma yükümlülüğü + tüm paketin AGPL kapsamına girmesi
/// riski). Bunun yerine yalnızca KULLANICININ sisteminde (Homebrew ile) kurulu `gs` aranır
/// (bkz. `EngineLocator.trimEngine()`); bulunamazsa "Kesim Payını At" işlemi nazikçe devre dışı
/// kalır (`OperationError.engineMissing`). Ölçüm ve karar gerekçesi:
/// `.claude/docs/yol-haritasi-2026-09.md` ("Motor lisansı" bölümü).
///
/// NOT (ölçüldü, 2026-09-07): gs, TrimBox'ı yeni MediaBox yaparken içeriği KIRPMAZ — yalnızca
/// koordinat kökenini kaydırır ve kutu üstverisini değiştirir. Sayfayla kesişen nesneler (ör.
/// kesim çizgisini aşan tam-sayfa bir taşma görseli) tam geometrisiyle kalır; yalnızca yeni
/// kutunun tamamen dışında kalan nesneler pratikte kaybolur. Bu yüzden `TrimVerification` gate'i
/// zorunlu: kutu üstverisine değil, gerçekten render edilen piksele bakar.
public struct GhostscriptEngine: TrimEngine {
  public let name = "gs"
  public let executable: URL
  public init(executable: URL) { self.executable = executable }

  public func trim(
    input: URL, output: URL,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    progress(0)
    let arguments = [
      "-q", "-o", output.path,
      "-sDEVICE=pdfwrite",
      "-dUseTrimBox",
      "-dPDFSETTINGS=/prepress",
      "-dBATCH", "-dNOPAUSE",
      input.path,
    ]
    let result = try await ProcessRunner.run(executable, arguments: arguments)
    guard result.status == 0 else {
      throw EngineError.failed(status: result.status, message: result.stderr + result.stdout)
    }
    progress(1)
  }
}
