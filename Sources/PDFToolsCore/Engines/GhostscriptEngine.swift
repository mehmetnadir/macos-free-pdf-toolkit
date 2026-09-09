import CoreGraphics
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
    // `-q` (quiet) KASITLI OLARAK VERİLMEZ: gs sessizleştirilmezse stdout'a sayfa başına
    // "Page N" satırı basar (ölçüldü: gs 10.05.1, banner + "Processing pages 1 through N."
    // başlığı da stdout'a gider, hiçbiri stderr'e değil). Bu satırlar aşağıda gerçek
    // ilerleme için ayrıştırılır; `trim` başarı koşulu yalnız `status == 0` olduğundan ekstra
    // stdout metni sonucu etkilemez.
    let total = CGPDFDocument(input as CFURL)?.numberOfPages ?? 0
    let arguments = [
      "-o", output.path,
      "-sDEVICE=pdfwrite",
      "-dUseTrimBox",
      "-dPDFSETTINGS=/prepress",
      "-dBATCH", "-dNOPAUSE",
      input.path,
    ]
    let result = try await ProcessRunner.run(executable, arguments: arguments) { line in
      guard total > 0, let page = Self.pageNumber(in: line) else { return }
      progress(Self.fraction(page: page, total: total))
    }
    guard result.status == 0 else {
      throw EngineError.failed(status: result.status, message: result.stderr + result.stdout)
    }
    progress(1)
  }

  /// gs'in sayfa ilerleme satırını ("Page N") ayrıştırır. Saf/test edilebilir fonksiyon —
  /// yalnızca TAM "Page <sayı>" satırlarını kabul eder; gs'in "Processing pages 1 through N."
  /// BAŞLIK satırı kelime olarak "pages" (küçük harf, çoğul) içerdiğinden ve satırın tamamını
  /// doldurmadığından yanlışlıkla eşleşmez.
  static func pageNumber(in line: String) -> Int? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("Page ") else { return nil }
    let digits = trimmed.dropFirst("Page ".count)
    guard !digits.isEmpty, digits.allSatisfy({ $0.isNumber }) else { return nil }
    return Int(digits)
  }

  /// `page`/`total`'ı 0...1'e sıkıştırır. gs bazen bildirilen toplamdan fazla "Page N" satırı
  /// basabilir (ör. ek/temizlik geçişi); üst sınır bu yüzden `min(1.0, …)` ile ZORUNLU.
  static func fraction(page: Int, total: Int) -> Double {
    min(1.0, Double(page) / Double(total))
  }
}
