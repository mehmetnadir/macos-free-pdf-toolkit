import CoreGraphics
import Foundation

/// PDF'i "Hızlı Web Görünümü" (linearized) biçimine dönüştürür: sayfalar internet üzerinden parça
/// parça indirilip açılabilir hale gelir — büyük ders kitaplarının tarayıcıda ilk sayfayı beklemeden
/// göstermesi için önemlidir. Motor: yalnız qpdf, `--linearize giriş çıkış` (gerçek komut çalıştırılıp
/// doğrulandı — bkz. `LinearizeVerification`). Çıktı: `<ad>_web.pdf`.
public struct LinearizeOperation: PDFOperation {
  public static let identifier = "linearize"
  public let id = LinearizeOperation.identifier
  public let title = "Optimize for Web"
  public let subtitle = "Reorganizes the PDF so pages can load progressively over the web"
  public let systemImage = "bolt"
  public let actionTitle = "Optimize for Web"
  public let outputSuffix = "_web"
  public var outputSuffixes: [String] { [outputSuffix] }

  public init() {}

  /// PDF spesifikasyonu gereği lineerleştirme sözlüğü (`/Linearized ...`) dosyanın EN BAŞINDAKİ ilk
  /// nesne olarak, SIKIŞTIRILMAMIŞ biçimde bulunur (hızlı-web-görünümünün çalışabilmesi zaten buna
  /// bağlıdır) — ölçülüp doğrulandı: gerçek bir `qpdf --linearize` çıktısında bu dizge ilk 400 bayt
  /// içinde düz metin olarak görünüyor. Bu yüzden ilk birkaç kilobaytı okuyup dizgeyi aramak ucuz ve
  /// eşzamanlı bir sezgisel sağlıyor — `PDFFileInfo` bu bilgiyi taşımadığından (ve bunu eklemek bu
  /// turun kapsamı dışında, paylaşılan dosyaya dokunmamak için) alt süreç çalıştırmadan (`qpdf`
  /// olmadan bile) "muhtemelen zaten hazır" sinyali verir. Kesin doğrulama yine `run()` sonrası
  /// `LinearizeVerification` ile yapılır; bu yalnızca kart görünümü/öneri içindir.
  public func applicability(for files: [PDFFileInfo]) -> OperationApplicability {
    guard !files.isEmpty else { return .notApplicable(reason: "Add a PDF first") }
    let eligible = files.filter { !Self.looksAlreadyLinearized($0.url) }.count
    guard eligible > 0 else { return .notApplicable(reason: "Already optimized for web") }
    return .applicable(fileCount: eligible)
  }

  private static let headerSniffBytes = 4096

  static func looksAlreadyLinearized(_ url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: headerSniffBytes) else { return false }
    return data.range(of: Data("/Linearized".utf8)) != nil
  }

  public func run(
    file: PDFFileInfo, context: OperationContext,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> OperationOutcome {
    switch file.lockState {
    case .unreadable: throw OperationError.unreadable
    case .passwordRequired: throw OperationError.passwordRequired
    case .restricted, .none: break
    }
    guard let qpdf = EngineLocator.find("qpdf") else {
      throw OperationError.engineMissing("qpdf engine not found")
    }

    let output = OutputNaming.uniqueURL(for: file.url, suffix: outputSuffix, in: context.outputDirectory)
    let partial = output.deletingLastPathComponent()
      .appendingPathComponent(".\(output.deletingPathExtension().lastPathComponent).part.pdf")
    let fm = FileManager.default
    try? fm.removeItem(at: partial)

    progress(0)
    do {
      let arguments = ["--linearize", file.url.path, partial.path]
      let result = try await ProcessRunner.run(qpdf, arguments: arguments)
      guard result.status == 0 || result.status == 3 else {
        throw EngineError.failed(status: result.status, message: result.stderr + result.stdout)
      }
    } catch is CancellationError {
      try? fm.removeItem(at: partial)
      throw CancellationError()
    } catch {
      try? fm.removeItem(at: partial)
      throw error
    }
    progress(0.7)

    // Kanıt 1: sayfa sayısı korunmuş mu.
    guard let doc = CGPDFDocument(partial as CFURL), doc.numberOfPages == file.pageCount else {
      try? fm.removeItem(at: partial)
      throw LinearizeError.verificationFailed("page count wasn't preserved")
    }
    progress(0.85)

    // Kanıt 2: qpdf --check çıktısı GERÇEKTEN "File is linearized" diyor mu — motorun sessizce
    // başarılı dönmesine güvenilmiyor (bkz. LinearizeVerification yorumu).
    let diagnosis = try await LinearizeVerification.diagnose(qpdf: qpdf, url: partial)
    guard diagnosis.isLinearized else {
      try? fm.removeItem(at: partial)
      throw LinearizeError.verificationFailed("qpdf --check didn't report the file as linearized")
    }

    try fm.moveItem(at: partial, to: output)
    progress(1)
    return .produced(urls: [output], note: nil)
  }
}

public enum LinearizeError: Error, LocalizedError, Equatable {
  /// `LinearizeVerification` çıktıyı doğrulayamadı; çıktı silinir, işlem hata döner.
  case verificationFailed(String)

  public var errorDescription: String? {
    switch self {
    case .verificationFailed(let detail):
      return "Web optimization could not be verified — \(detail) — output deleted"
    }
  }
}
