import CoreGraphics
import Foundation

/// Listedeki tüm dosyaları listedeki SIRAYLA tek PDF'te birleştirir. Motor: qpdf
/// `--empty --pages a.pdf b.pdf ... -- out.pdf` (aslına sadık sayfa kopyası, yeniden damıtma yok).
/// Tüm bekleyen dosyalar TEK çağrıda işlenir (bkz. `arity == .combined`) — dosya başına değil.
/// Çıktı: ilk dosyanın adından türetilir, sonek `_birlesik` (kaynağın yanına ya da seçilen klasöre).
public struct MergeOperation: PDFOperation {
  public static let identifier = "merge"
  public let id = MergeOperation.identifier
  public let title = "Birleştir"
  public let subtitle = "Listedeki tüm dosyaları listedeki sırayla tek PDF'te birleştirir"
  public let systemImage = "doc.on.doc"
  public let actionTitle = "Birleştir"
  public let arity: OperationArity = .combined
  public let outputSuffix = "_birlesik"

  public init() {}

  public func runCombined(
    files: [PDFFileInfo], context: OperationContext,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> OperationOutcome {
    guard !files.isEmpty else { return .skipped(reason: "Birleştirilecek dosya yok") }
    guard files.count > 1 else { return .skipped(reason: "Birleştirmek için en az iki dosya gerekli") }

    for file in files {
      switch file.lockState {
      case .unreadable: throw OperationError.unreadable
      // qpdf, kullanıcı şifresi boş olan (yalnızca sahip/izin kısıtlı) dosyaları şifre vermeden
      // okuyabilir — burada engellemenin teknik gerekçesi yok (bkz. TrimOperation'daki aynı karar).
      // Yalnızca gerçekten kullanıcı şifresi gereken dosyalar merge'ün elinde yok (parola parametresi
      // bu komutta yok), o yüzden yalnız bu durum hataya düşer.
      case .passwordRequired: throw OperationError.passwordRequired
      case .restricted, .none: continue
      }
    }

    guard let qpdf = EngineLocator.find("qpdf") else {
      throw OperationError.engineMissing("qpdf motoru bulunamadı")
    }

    progress(0)
    let firstInput = files[0].url
    let output = OutputNaming.uniqueURL(for: firstInput, suffix: outputSuffix, in: context.outputDirectory)
    let partial = output.deletingLastPathComponent()
      .appendingPathComponent(".\(output.deletingPathExtension().lastPathComponent).part.pdf")
    let fm = FileManager.default
    try? fm.removeItem(at: partial)

    var arguments = ["--empty", "--pages"]
    arguments += files.map(\.url.path)
    arguments += ["--", partial.path]

    do {
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
    progress(0.9)

    // Kanıt: çıktı sayfa sayısı == girdilerin toplamı. Sayfa içeriğinin doğru konuma taşındığının
    // (metin dahil) daha derin kanıtı `MergeVerification.pagesMatch` ile testlerde ölçülür.
    let expectedPages = files.reduce(0) { $0 + $1.pageCount }
    guard MergeVerification.pageCountMatches(partial, expected: expectedPages) else {
      try? fm.removeItem(at: partial)
      throw OperationError.mergeVerificationFailed
    }

    try fm.moveItem(at: partial, to: output)
    progress(1)
    return .produced(urls: [output], note: nil)
  }
}
